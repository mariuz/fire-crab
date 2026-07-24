#!/bin/bash
# A VARCHAR column's FORMAT DESCRIPTOR is byte-exact.
#
# A relation's RDB$FORMATS descriptor packs one (dtype, dsc_length, scale,
# sub_type) tuple per column. For VARYING the descriptor length INCLUDES the
# 2-byte count word: VARCHAR(6) => dsc_length 8, not 6 and not 10. fire-crab
# once double-counted it (a ColumnDef's declared length already carries the
# +2, and compute_format re-added it), writing dsc_length 10 - a latent
# byte-fidelity bug no gate caught because none byte-compared the format blob.
# The same +2 fed RDB$RUNTIME's RSR_field_length/RSR_character_length, so an
# ALTER re-derived a VARCHAR's character length as 8 where the engine has 6.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine each create the same mixed-type table on two
#      copies; the RDB$FORMATS descriptor blob is compared BYTE FOR BYTE
#      (dtype, dsc_length AND the packed offsets of every following column);
#   2. after an ALTER TABLE ADD, the rebuilt RDB$RUNTIME is compared byte for
#      byte (the VARCHAR character length survives the rebuild correctly);
#   3. the engine reads a row fire-crab INSERTed into its VARCHAR/CHAR columns;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-varcharfmt.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4181}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-vcf-work.fdb"; REF="$D/fc-vcf-ref.fdb"
FBK="$D/fc-vcf-work.fbk"; RST="$D/fc-vcf-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# a mix so the descriptor pack exercises alignment AFTER a VARYING:
# INTEGER (4) | VARCHAR(6) (dsc 8) | CHAR(4) (4) | VARCHAR(20) (dsc 22)
DDL="CREATE TABLE T (A INTEGER, B VARCHAR(6), C CHAR(4), N VARCHAR(20))"
ALT="ALTER TABLE T ADD E INTEGER"
INS="INSERT INTO T (A, B, C, N) VALUES (1, 'abc', 'xy', 'hello world')"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL; $ALT;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-vcf.log 2>&1 &
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
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

check "fire-crab creates the mixed-type table" "$(node_run "$DDL")" "OK"
check "fire-crab ALTER TABLE ADD (rebuilds the runtime)" "$(node_run "$ALT")" "OK"
check "fire-crab INSERTs a row into the VARCHAR/CHAR columns" "$(node_run "$INS")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RDB$FORMATS descriptor, byte for byte ----------------------
fmtq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT f.RDB$DESCRIPTOR FROM RDB$FORMATS f
  JOIN RDB$RELATIONS r ON r.RDB$RELATION_ID = f.RDB$RELATION_ID
  WHERE r.RDB$RELATION_NAME = 'T' ORDER BY f.RDB$FORMAT DESC ROWS 1;
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-vcf-fmt.bin
    printf 'BLOBDUMP %s /tmp/fc-vcf-fmt.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-vcf-fmt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_fmt=$(fmtq "$WORK")
check "the RDB\$FORMATS descriptor matches the engine byte for byte" "$work_fmt" "$(fmtq "$REF")"
# teeth: the VARCHAR(6) descriptor really carries dsc_length 8 (dtype 3, len 8),
# NOT the double-counted 10; the engine's own blob decides, this just proves
# the comparison wasn't vacuous.
case "$work_fmt" in
    *" 3 0 8 0 "*) echo "OK   the VARCHAR(6) descriptor carries dsc_length 8 (count word once)" ;;
    *) echo "DIFF the VARCHAR descriptor length is wrong (double-counted?)"; echo "     $work_fmt"; fail=1 ;;
esac

# --- 2. the rebuilt RDB$RUNTIME, byte for byte -------------------------
rtq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-vcf-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-vcf-rt.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-vcf-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "RDB\$RUNTIME matches the engine byte for byte after the ALTER" "$(rtq "$WORK")" "$(rtq "$REF")"

# --- 3. the engine reads fire-crab's row -------------------------------
row=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A||'|'||TRIM(B)||'|'||TRIM(C)||'|'||TRIM(N) FROM T;
SQL
)
check "the engine reads the VARCHAR/CHAR row fire-crab wrote" "$row" "1|abc|xy|hello world"

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-vcf-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-vcf-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-vcf-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-vcf-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-vcf-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
