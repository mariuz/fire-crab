#!/bin/bash
# ALTER TABLE ADD of COMPUTED BY columns - and ALTERs on computed tables.
#
# Adding a computed column is a new format version like any ADD (probed:
# RDB$FORMAT 1 -> 2), whose new descriptor carries the inferred result
# type at OFFSET 0 while every stored field keeps its offset; the
# RDB$FIELDS row carries RDB$COMPUTED_SOURCE/BLR + precision exactly as
# CREATE TABLE writes them, and the rebuilt RDB$RUNTIME re-emits every
# computed field's RSR_computed_blr(4) segment - the piece that also
# unlocks runtime-only ALTERs (SET DEFAULT & co.) on computed tables.
# Adding a PLAIN column to a computed table must land it after the last
# STORED field (probed: BIGINT onto `(A INT, C COMPUTED BY (A))` -> @8).
# Old rows (old format) read promoted, computing the new column.
#
# The differential is the engine, six ways: identical engine-created
# base tables on two copies, the ALTERs done by fire-crab (work) vs the
# engine (ref); then computed-field catalog values, both tables' format-2
# descriptors and RDB$RUNTIME blobs BYTE FOR BYTE, RDB$RELATIONS
# format/field-count, the engine inserting + evaluating from fc's file,
# a fire-crab-served SELECT over OLD rows, an fc SET DEFAULT on the
# computed table (runtime re-emit teeth) compared byte-for-byte again,
# and gbak + gfix. INT128 results and computed-over-computed refuse.
#
#   qa/serve-real-altercomputed.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4246}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-altcomp-work.fdb"; REF="$D/fc-altcomp-ref.fdb"
FBK="$D/fc-altcomp-work.fbk"; RST="$D/fc-altcomp-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

BASE="CREATE TABLE AT1 (A INTEGER, B INTEGER);
CREATE TABLE AT2 (A INTEGER, C COMPUTED BY (A));
COMMIT;
INSERT INTO AT1 VALUES (1, 2);
INSERT INTO AT1 (A) VALUES (7);
INSERT INTO AT2 (A) VALUES (4);
COMMIT;"
A1="ALTER TABLE AT1 ADD C COMPUTED BY (A+B)"
A2="ALTER TABLE AT2 ADD B BIGINT"
A3="ALTER TABLE AT2 ALTER COLUMN A SET DEFAULT 5"

for db in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $db"; exit 1; }
CREATE DATABASE '$db' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$BASE
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF || { echo "FAIL ref alters"; exit 1; }
$A1; $A2; COMMIT; $A3; COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-altcomp.log 2>&1 &
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
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          console.log(r.map(row=>Object.values(row).map(v=>v===null?"NULL":String(v)).join("|")).join(" / "));
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

check "fire-crab: ALTER ADD a computed column" "$(node_run "$A1")" "OK"
check "fire-crab: ALTER ADD a plain BIGINT to a computed table" "$(node_run "$A2")" "OK"
case "$(node_run 'ALTER TABLE AT2 ADD X COMPUTED BY (B*2)')" in
    ERR*) echo "OK   an INT128 result is REFUSED in ALTER too" ;;
    *) echo "DIFF ALTER INT128 refusal"; fail=1 ;; esac
case "$(node_run 'ALTER TABLE AT1 ADD Y COMPUTED BY (C+1)')" in
    ERR*) echo "OK   computed-over-computed is refused (not typed wrong)" ;;
    *) echo "DIFF computed-over-computed refusal"; fail=1 ;; esac
# the added column evaluates over OLD rows (old-format records promote)
check "fire-crab serves the added column over pre-ALTER rows" \
    "$(node_run 'SELECT A, B, C FROM AT1')" "1|2|3 / 7|NULL|NULL"
# a runtime-only ALTER on a computed table (the rebuilt RDB$RUNTIME must
# re-emit the computed segment or the column stops computing)
check "fire-crab: SET DEFAULT on a computed table's stored column" "$(node_run "$A3")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# identical engine-side inserts on both files (AT2's DEFAULT applies)
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO AT1 (A, B) VALUES (10, 100);
INSERT INTO AT2 (B) VALUES (900);
COMMIT;
SQL
}
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*) echo "DIFF engine inserts into fc-altered tables"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine inserts into fire-crab's altered tables" ;; esac

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(rf.RDB$RELATION_NAME)||'.'||TRIM(rf.RDB$FIELD_NAME)||'|'||f.RDB$FIELD_TYPE||'|'||f.RDB$FIELD_LENGTH||'|'||f.RDB$FIELD_SCALE||'|'||f.RDB$FIELD_SUB_TYPE||'|'||f.RDB$FIELD_PRECISION||'|'||rf.RDB$UPDATE_FLAG||'|'||rf.RDB$COLLATION_ID||'|'||CAST(f.RDB$COMPUTED_SOURCE AS VARCHAR(60))||'|'||CAST(CAST(f.RDB$COMPUTED_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(120) CHARACTER SET OCTETS)
FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE
WHERE rf.RDB$RELATION_NAME IN ('AT1','AT2') AND f.RDB$COMPUTED_BLR IS NOT NULL
ORDER BY rf.RDB$RELATION_NAME, rf.RDB$FIELD_POSITION;
SELECT TRIM(r.RDB$RELATION_NAME)||'|'||r.RDB$FORMAT||'|'||r.RDB$FIELD_ID FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME IN ('AT1','AT2') ORDER BY 1;
SELECT TRIM(r.RDB$RELATION_NAME)||'#'||f.RDB$FORMAT FROM RDB$FORMATS f JOIN RDB$RELATIONS r ON r.RDB$RELATION_ID=f.RDB$RELATION_ID WHERE r.RDB$RELATION_NAME IN ('AT1','AT2') ORDER BY 1;
SQL
}
work_c=$(catq "$WORK")
check "computed catalog + format/field counts match the engine" "$work_c" "$(catq "$REF")"
case "$work_c" in *"AT1|2|3"*) echo "OK   vacuous-guard: the ALTER bumped AT1 to format 2, 3 fields" ;;
    *) echo "DIFF vacuous fmt"; echo "     $work_c"; fail=1 ;; esac

# both tables' NEWEST format descriptor, byte for byte
fmtq() { # <db> <table> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT f.RDB\$DESCRIPTOR FROM RDB\$FORMATS f JOIN RDB\$RELATIONS r ON r.RDB\$RELATION_ID = f.RDB\$RELATION_ID WHERE r.RDB\$RELATION_NAME='$2' AND f.RDB\$FORMAT=2;
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-altcomp-fmt-$3.bin"
    printf 'BLOBDUMP %s /tmp/fc-altcomp-fmt-%s.bin;\n' "$b" "$3" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-altcomp-fmt-$3.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "AT1's format-2 descriptor matches byte for byte (computed appended at offset 0)" \
    "$(fmtq "$WORK" AT1 w1)" "$(fmtq "$REF" AT1 r1)"
check "AT2's format-2 descriptor matches byte for byte (stored walk skips the computed)" \
    "$(fmtq "$WORK" AT2 w2)" "$(fmtq "$REF" AT2 r2)"

rtq() { # <db> <table> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB\$RUNTIME FROM RDB\$RELATIONS r WHERE r.RDB\$RELATION_NAME='$2';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-altcomp-rt-$3.bin"
    printf 'BLOBDUMP %s /tmp/fc-altcomp-rt-%s.bin;\n' "$b" "$3" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-altcomp-rt-$3.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "AT1's rebuilt RDB\$RUNTIME matches byte for byte (computed segment re-emitted)" \
    "$(rtq "$WORK" AT1 w1)" "$(rtq "$REF" AT1 r1)"
check "AT2's RDB\$RUNTIME matches byte for byte after ADD + SET DEFAULT" \
    "$(rtq "$WORK" AT2 w2)" "$(rtq "$REF" AT2 r2)"

# the engine evaluates everything from fc's file - old rows, new rows,
# the applied DEFAULT, NULL propagation
valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'AT1', A, B, C FROM AT1 ORDER BY A;
SELECT 'AT2', A, C, B FROM AT2 ORDER BY A;
SQL
}
work_v=$(valq "$WORK")
check "the engine SELECTs old + new rows with computed values from fc's file" \
    "$work_v" "$(valq "$REF")"
case "$work_v" in *"<null>"*) echo "OK   vacuous-guard: a NULL-propagating row is included" ;;
    *) echo "DIFF vacuous null"; fail=1 ;; esac
case "$work_v" in *" 5 "*|*"5|"*) echo "OK   vacuous-guard: the fc-written DEFAULT applied on insert" ;;
    *) echo "DIFF vacuous default"; echo "     $work_v"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-altcomp-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab altered"
else echo "DIFF gbak backup"; cat /tmp/fc-altcomp-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-altcomp-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-altcomp-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-altcomp-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
