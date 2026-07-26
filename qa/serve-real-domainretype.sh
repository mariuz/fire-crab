#!/bin/bash
# IN-USE domain retype: ALTER DOMAIN ... TYPE with dependent tables -
# the engine-parity slice replacing inc 123's conservative refusal.
#
# The engine (probed): patches the domain's RDB$FIELDS row once, then
# gives EVERY dependent table exactly ONE new format version per
# statement - however many of its columns use the domain - and leaves
# old records in their old format, reading back promoted. A dependent
# column inside a FOREIGN KEY index still refuses ("Cannot modify index
# used by an Integrity Constraint").
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine run the same ALTER DOMAIN statements on
#      two engine-created copies; the domain rows, the RDB$FORMATS rows
#      AND their descriptor blobs (byte for byte), the current format
#      numbers and the dependent tables' RDB$RUNTIME blobs all match;
#   2. old rows read back promoted through fire-crab AND fire-crab
#      writes a new-format row past the old width itself;
#   3. the FK-child domain still refuses, on both servers;
#   4. the engine adopts fc's file: reads the promoted+wide rows,
#      writes another wide row;
#   5. gbak round trip and gfix -v -full.
#
#   qa/serve-real-domainretype.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4285}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dret-work.fdb"; REF="$D/fc-dret-ref.fdb"
FBK="$D/fc-dret-work.fbk"; RST="$D/fc-dret-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE DOMAIN DI AS INTEGER;
CREATE DOMAIN DV AS VARCHAR(6);
CREATE DOMAIN DFK AS INTEGER;
CREATE TABLE U1 (A DI, B VARCHAR(5), C DI);
CREATE TABLE U2 (X DI, Y DV);
CREATE TABLE U3 (Z INTEGER);
CREATE TABLE FM (Q INTEGER NOT NULL PRIMARY KEY);
CREATE TABLE FC2 (R DFK REFERENCES FM (Q));
COMMIT;
INSERT INTO U1 VALUES (1, 'ab', 2);
INSERT INTO U2 VALUES (7, 'cd');
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dret.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_ddl() {
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
node_rows() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          for(const row of (r||[]))
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
retry() { # <fn> <query>
    n=0
    while [ $n -lt 10 ]; do
        r=$("$1" "$2")
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

# --- 1. the ALTERs through fire-crab -----------------------------------
check "fire-crab: ALTER DOMAIN DI TYPE BIGINT (2 tables, 3 columns)" \
      "$(retry node_ddl 'ALTER DOMAIN DI TYPE BIGINT')" "OK"
check "fire-crab: ALTER DOMAIN DV TYPE VARCHAR(20)" \
      "$(retry node_ddl 'ALTER DOMAIN DV TYPE VARCHAR(20)')" "OK"
case "$(retry node_ddl 'ALTER DOMAIN DFK TYPE BIGINT')" in
    ERR*) echo "OK   the FK-child domain still refuses" ;;
    *) echo "DIFF FK-child domain guard"; fail=1 ;; esac
# old rows promoted through fc, and fc WRITES a new-format wide row
check "fc reads old rows promoted" "$(retry node_rows 'SELECT A, B, C FROM U1 ORDER BY A')" "1|ab|2"
check "fc writes a past-INTEGER row into the new format" \
      "$(retry node_ddl "INSERT INTO U1 VALUES (6000000000, 'wz', 9000000000)")" "OK"
check "fc reads both formats together" \
      "$(retry node_rows 'SELECT A, C FROM U1 ORDER BY A')" "1|2
6000000000|9000000000"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. the engine runs the identical statements on the ref ------------
"$ISQL" -q -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
ALTER DOMAIN DI TYPE BIGINT;
COMMIT;
ALTER DOMAIN DV TYPE VARCHAR(20);
COMMIT;
INSERT INTO U1 VALUES (6000000000, 'wz', 9000000000);
COMMIT;
SQL

catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'DOM|'||TRIM(f.RDB$FIELD_NAME)||'|'||f.RDB$FIELD_TYPE||'|'||f.RDB$FIELD_LENGTH
       ||'|'||COALESCE(f.RDB$FIELD_SUB_TYPE,-99)||'|'||COALESCE(f.RDB$FIELD_PRECISION,-99)
       ||'|'||COALESCE(f.RDB$CHARACTER_LENGTH,-99)
FROM RDB$FIELDS f WHERE f.RDB$FIELD_NAME IN ('DI','DV','DFK') ORDER BY 1;
SELECT 'FMT|'||TRIM(r.RDB$RELATION_NAME)||'|'||fmt.RDB$FORMAT
FROM RDB$FORMATS fmt JOIN RDB$RELATIONS r ON r.RDB$RELATION_ID = fmt.RDB$RELATION_ID
WHERE r.RDB$RELATION_NAME IN ('U1','U2','U3') ORDER BY r.RDB$RELATION_NAME, fmt.RDB$FORMAT;
SELECT 'CUR|'||TRIM(RDB$RELATION_NAME)||'|'||RDB$FORMAT FROM RDB$RELATIONS
WHERE RDB$RELATION_NAME IN ('U1','U2','U3') ORDER BY RDB$RELATION_NAME;
SQL
}
work_c=$(catq "$WORK")
check "domain rows, format lists and current formats match the engine" "$work_c" "$(catq "$REF")"
case "$work_c" in
    *"FMT|U1|2"*"FMT|U2|3"*"CUR|U1|2"*"CUR|U2|3"*"CUR|U3|1"*)
        echo "OK   the teeth bite: U1 one bump (2 cols), U2 two bumps (DI then DV), U3 untouched" ;;
    *) echo "DIFF the format comparison was vacuous"; echo "     $work_c"; fail=1 ;;
esac

# --- 3. descriptor + runtime blobs byte for byte ------------------------
blobq() { # <file> <select yielding one blob id>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
$2
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dret-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-dret-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dret-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
for spec in "U1 2" "U2 2" "U2 3"; do
    t=${spec% *}; n=${spec#* }
    q="SELECT fmt.RDB\$DESCRIPTOR FROM RDB\$FORMATS fmt JOIN RDB\$RELATIONS r ON r.RDB\$RELATION_ID = fmt.RDB\$RELATION_ID WHERE r.RDB\$RELATION_NAME = '$t' AND fmt.RDB\$FORMAT = $n;"
    check "$t format $n descriptors match byte for byte" "$(blobq "$WORK" "$q")" "$(blobq "$REF" "$q")"
done
for t in U1 U2; do
    q="SELECT RDB\$RUNTIME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = '$t';"
    check "$t RDB\$RUNTIME matches byte for byte" "$(blobq "$WORK" "$q")" "$(blobq "$REF" "$q")"
done

# --- 4. the engine adopts fire-crab's file ------------------------------
adopt() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
INSERT INTO U2 VALUES (8000000000, 'abcdefghijklmnop');
COMMIT;
SET HEADING OFF;
SELECT 'U1|'||A||'|'||B||'|'||C FROM U1 ORDER BY A;
SELECT 'U2|'||X||'|'||TRIM(Y) FROM U2 ORDER BY X;
SQL
}
check "the engine reads fc's promoted+wide rows and writes its own" \
      "$(adopt "$WORK")" "$(adopt "$REF")"
engref=$("$ISQL" -q -user "$U" -pas "$P" "$WORK" 2>&1 <<< "ALTER DOMAIN DFK TYPE BIGINT;")
case "$engref" in
    *"Integrity Constraint"*) echo "OK   the engine refuses the FK-child domain on fc's file too" ;;
    *) echo "DIFF engine-side FK-domain refusal"; echo "     $engref"; fail=1 ;;
esac

# --- 5. gbak and gfix ----------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dret-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dret-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dret-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dret-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dret-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
