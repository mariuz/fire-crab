#!/bin/bash
# ALTER DOMAIN <old> TO <new> - rename, including a domain in use.
#
# The rename patches the RDB$FIELDS row IN PLACE - which changes the
# row's key in the catalog's unique name index, so the NEW name must be
# keyed in (the old entry stays behind pointing at the live row, the
# same stale shape every engine update leaves until GC; what matters is
# that the CURRENT name is findable). Every column using the domain gets
# its RDB$FIELD_SOURCE patched and its table's RDB$RUNTIME rebuilt - the
# summary quotes the source name (all probed: the engine updates both,
# and the domain's DEFAULT keeps applying afterwards).
#
# The differential is the engine, six ways:
#   1. fire-crab and the engine rename an unused and an IN-USE domain;
#      RDB$FIELDS, every column's RDB$FIELD_SOURCE and the using table's
#      RDB$RUNTIME (byte for byte) are compared;
#   2. the INDEX teeth: the engine resolves the renamed domain BY NAME
#      from fire-crab's raw file (CREATE TABLE ... <new name> - the
#      lookup goes through the unique name index, so a missing entry
#      would be "domain not defined"), and the OLD name errors
#      identically on both files;
#   3. the domain's DEFAULT still applies through the new name;
#   4. renames of a nonexistent domain, onto a taken name, and of a
#      system domain all refuse;
#   5. final contents identical;
#   6. gfix -v -full (which validates records against index entries) and
#      a gbak round trip.
#
#   qa/serve-real-domainrename.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4267}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-domren-work.fdb"; REF="$D/fc-domren-ref.fdb"
FBK="$D/fc-domren-work.fbk"; RST="$D/fc-domren-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

BASE="CREATE DOMAIN DOM_A AS INTEGER;
CREATE DOMAIN DOM_B AS INTEGER DEFAULT 5;
CREATE DOMAIN DOM_KEEP AS INTEGER;
CREATE TABLE TD1 (X DOM_B, Y INTEGER);
COMMIT;"
R1="ALTER DOMAIN DOM_A TO DOM_RENAMED"
R2="ALTER DOMAIN DOM_B TO DOM_USED"

for db in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $db"; exit 1; }
CREATE DATABASE '$db' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$BASE
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF || { echo "FAIL ref renames"; exit 1; }
$R1; COMMIT; $R2; COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-domren.log 2>&1 &
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

check "fire-crab: rename an unused domain" "$(node_run "$R1")" "OK"
check "fire-crab: rename a domain IN USE" "$(node_run "$R2")" "OK"
case "$(node_run 'ALTER DOMAIN DOM_NOPE TO DOM_X')" in
    ERR*) echo "OK   renaming a nonexistent domain refuses" ;;
    *) echo "DIFF nonexistent refusal"; fail=1 ;; esac
case "$(node_run 'ALTER DOMAIN DOM_RENAMED TO DOM_KEEP')" in
    ERR*) echo "OK   renaming onto a taken name refuses" ;;
    *) echo "DIFF taken-name refusal"; fail=1 ;; esac
case "$(node_run 'ALTER DOMAIN RDB$1 TO DOM_SYS')" in
    ERR*) echo "OK   renaming a system domain refuses" ;;
    *) echo "DIFF system refusal"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(f.RDB$FIELD_NAME) FROM RDB$FIELDS f WHERE f.RDB$FIELD_NAME STARTING WITH 'DOM' ORDER BY 1;
SELECT TRIM(rf.RDB$FIELD_NAME)||'|'||TRIM(rf.RDB$FIELD_SOURCE) FROM RDB$RELATION_FIELDS rf WHERE rf.RDB$RELATION_NAME='TD1' ORDER BY rf.RDB$FIELD_POSITION;
SQL
}
work_c=$(catq "$WORK")
check "RDB\$FIELDS names and column sources match the engine" "$work_c" "$(catq "$REF")"
case "$work_c" in *"X|DOM_USED"*) echo "OK   vacuous-guard: the in-use column's source is the NEW name" ;;
    *) echo "DIFF vacuous source"; echo "     $work_c"; fail=1 ;; esac

rtq() { # <db> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB$RUNTIME FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME='TD1';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-domren-rt-$2.bin"
    printf 'BLOBDUMP %s /tmp/fc-domren-rt-%s.bin;\n' "$b" "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-domren-rt-$2.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "TD1's rebuilt RDB\$RUNTIME matches byte for byte (new source name quoted)" \
    "$(rtq "$WORK" w)" "$(rtq "$REF" r)"

# the INDEX teeth: the engine resolves the renamed domain BY NAME from
# fc's raw file - the lookup goes through the unique name index
newuse() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
CREATE TABLE TD2 (Z DOM_USED, V DOM_RENAMED);
COMMIT;
INSERT INTO TD1 (Y) VALUES (1);
INSERT INTO TD2 (V) VALUES (9);
COMMIT;
SQL
}
newuse "$REF" >/dev/null 2>&1
outw=$(newuse "$WORK")
case "$outw" in *[Ee]rror*|*SQLSTATE*) echo "DIFF the engine could not resolve the renamed domains"; echo "     $outw"; fail=1 ;;
    *) echo "OK   the engine resolves BOTH renamed domains by name from fc's file" ;; esac
oldq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
CREATE TABLE TD3 (W DOM_B);
SQL
}
work_o=$(oldq "$WORK")
check "the OLD name errors identically on both files" "$work_o" "$(oldq "$REF")"
case "$work_o" in SQLSTATE*) echo "OK   vacuous-guard: the old-name failure is a real SQL error" ;;
    *) echo "DIFF vacuous old"; fail=1 ;; esac

valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'TD1', X, Y FROM TD1;
SELECT 'TD2', Z, V FROM TD2;
SQL
}
work_v=$(valq "$WORK")
check "contents identical (the domain DEFAULT applied through the new name)" \
    "$work_v" "$(valq "$REF")"
case "$work_v" in *"5            1"*|*"5 1"*)
    echo "OK   vacuous-guard: the renamed domain's DEFAULT 5 landed" ;;
    *) echo "DIFF vacuous default"; echo "     $work_v"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-domren-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-domren-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-domren-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-domren-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-domren-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (record-vs-index validation included)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
