#!/bin/bash
# DROP COLUMN and ALTER TYPE around COMPUTED BY columns.
#
# Four engine-probed rules drive this slice:
#   - dropping a STORED column a computed expression references is
#     refused ("there are N dependencies") - fire-crab reads each
#     computed field's RDB$COMPUTED_BLR back and refuses when the
#     dropped name appears (or when the BLR is outside the surface it
#     can read - assume it references anything);
#   - dropping the last stored column is refused ("can't have relation
#     with only computed fields or constraints");
#   - dropping the COMPUTED column itself is an ordinary drop: an
#     all-zero placeholder in a new format version, catalog rows gone;
#   - ALTER TYPE of the computed column refuses ("cannot add or remove
#     COMPUTED"), but ALTER TYPE of a REFERENCED stored column is
#     ALLOWED - and leaves the computed column's declared type STALE
#     (probed: A INTEGER -> BIGINT keeps C COMPUTED BY (A) a LONG).
# Surviving computed fields keep their offset-0 descriptors through
# every format recompute.
#
# The differential is the engine: identical engine-created base tables
# (with rows) on two copies, the ALTERs done by fire-crab (work) vs the
# engine (ref); then catalog + format/field counts, every new format
# descriptor and RDB$RUNTIME blob BYTE FOR BYTE, the engine evaluating
# computed columns from fc's file (stale-type case included), fire-crab
# serving post-drop SELECTs, and gbak + gfix.
#
#   qa/serve-real-dropcomputed.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4247}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dropcomp-work.fdb"; REF="$D/fc-dropcomp-ref.fdb"
FBK="$D/fc-dropcomp-work.fbk"; RST="$D/fc-dropcomp-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

BASE="CREATE TABLE DT1 (A INTEGER, B INTEGER, C COMPUTED BY (A+B), D INTEGER);
CREATE TABLE DT2 (A INTEGER, B INTEGER, C COMPUTED BY (A));
CREATE TABLE DT3 (A INTEGER, C COMPUTED BY (A));
CREATE TABLE DT4 (A INTEGER, S SMALLINT, C COMPUTED BY (A*2));
COMMIT;
INSERT INTO DT1 VALUES (1, 2, 9);
INSERT INTO DT1 (A) VALUES (7);
INSERT INTO DT3 (A) VALUES (5);
INSERT INTO DT4 (A, S) VALUES (6, 1);
COMMIT;"
S1="ALTER TABLE DT1 DROP D"
S2="ALTER TABLE DT2 DROP C"
S3="ALTER TABLE DT3 ALTER COLUMN A TYPE BIGINT"
S4="ALTER TABLE DT4 ALTER COLUMN S TYPE INTEGER"

for db in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $db"; exit 1; }
CREATE DATABASE '$db' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$BASE
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF || { echo "FAIL ref alters"; exit 1; }
$S1; COMMIT; $S2; COMMIT; $S3; COMMIT; $S4; COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dropcomp.log 2>&1 &
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

check "fire-crab: DROP a plain column from a computed table" "$(node_run "$S1")" "OK"
check "fire-crab: DROP the computed column itself" "$(node_run "$S2")" "OK"
case "$(node_run 'ALTER TABLE DT3 DROP A')" in
    ERR*) echo "OK   dropping the last stored column is refused" ;;
    *) echo "DIFF only-computed refusal"; fail=1 ;; esac
case "$(node_run 'ALTER TABLE DT4 DROP A')" in
    ERR*) echo "OK   dropping a column a computed expression references is refused" ;;
    *) echo "DIFF dependency refusal"; fail=1 ;; esac
case "$(node_run 'ALTER TABLE DT4 ALTER COLUMN C TYPE BIGINT')" in
    ERR*) echo "OK   retyping the computed column itself is refused" ;;
    *) echo "DIFF computed-retype refusal"; fail=1 ;; esac
check "fire-crab: ALTER TYPE of a REFERENCED stored column (stale computed type)" \
    "$(node_run "$S3")" "OK"
check "fire-crab: ALTER TYPE of an unreferenced column in a computed table" \
    "$(node_run "$S4")" "OK"
# post-drop serving: the computed column still evaluates on DT1; DT2's
# dropped one is gone from *
check "fire-crab serves the computed column after the sibling drop" \
    "$(node_run 'SELECT A, B, C FROM DT1')" "1|2|3 / 7|NULL|NULL"
check "fire-crab: SELECT * no longer carries the dropped computed column" \
    "$(node_run 'SELECT * FROM DT2')" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# identical engine-side inserts on both files, then values compare
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO DT1 (A, B) VALUES (10, 100);
INSERT INTO DT2 (A, B) VALUES (11, 12);
INSERT INTO DT3 (A) VALUES (3000000000);
INSERT INTO DT4 (A, S) VALUES (8, 70000);
COMMIT;
SQL
}
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*) echo "DIFF engine inserts into fc-altered tables"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine inserts into fire-crab's altered tables (widened cols included)" ;; esac

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(rf.RDB$RELATION_NAME)||'.'||TRIM(rf.RDB$FIELD_NAME)||'|'||f.RDB$FIELD_TYPE||'|'||f.RDB$FIELD_LENGTH||'|'||f.RDB$FIELD_PRECISION||'|'||rf.RDB$FIELD_ID||'|'||rf.RDB$FIELD_POSITION
FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE
WHERE rf.RDB$RELATION_NAME IN ('DT1','DT2','DT3','DT4')
ORDER BY rf.RDB$RELATION_NAME, rf.RDB$FIELD_POSITION;
SELECT TRIM(r.RDB$RELATION_NAME)||'|'||r.RDB$FORMAT||'|'||r.RDB$FIELD_ID FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME IN ('DT1','DT2','DT3','DT4') ORDER BY 1;
SQL
}
work_c=$(catq "$WORK")
check "surviving columns, formats and field counts match the engine" "$work_c" "$(catq "$REF")"
# the stale-type teeth: DT3.A is INT64 (16/8) while DT3.C stays LONG (8/4/9)
case "$work_c" in *"DT3.A|16|8|0|0|0"*)
    case "$work_c" in *"DT3.C|8|4|9|1|1"*)
        echo "OK   vacuous-guard: A widened to BIGINT, C's declared type stayed LONG" ;;
        *) echo "DIFF vacuous stale"; echo "     $work_c"; fail=1 ;; esac ;;
    *) echo "DIFF vacuous widen"; echo "     $work_c"; fail=1 ;; esac

# every table's NEWEST format descriptor, byte for byte
fmtq() { # <db> <table> <fmt> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT f.RDB\$DESCRIPTOR FROM RDB\$FORMATS f JOIN RDB\$RELATIONS r ON r.RDB\$RELATION_ID = f.RDB\$RELATION_ID WHERE r.RDB\$RELATION_NAME='$2' AND f.RDB\$FORMAT=$3;
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-dropcomp-fmt-$4.bin"
    printf 'BLOBDUMP %s /tmp/fc-dropcomp-fmt-%s.bin;\n' "$b" "$4" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-dropcomp-fmt-$4.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
for t in DT1 DT2 DT3 DT4; do
    check "$t's format-2 descriptor matches byte for byte" \
        "$(fmtq "$WORK" $t 2 w$t)" "$(fmtq "$REF" $t 2 r$t)"
done

rtq() { # <db> <table> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB\$RUNTIME FROM RDB\$RELATIONS r WHERE r.RDB\$RELATION_NAME='$2';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-dropcomp-rt-$3.bin"
    printf 'BLOBDUMP %s /tmp/fc-dropcomp-rt-%s.bin;\n' "$b" "$3" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-dropcomp-rt-$3.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
for t in DT1 DT2 DT3; do
    check "$t's rebuilt RDB\$RUNTIME matches byte for byte" \
        "$(rtq "$WORK" $t w$t)" "$(rtq "$REF" $t r$t)"
done

# the engine evaluates everything from fc's file
valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'DT1', A, B, C FROM DT1 ORDER BY A;
SELECT 'DT2', A, B FROM DT2 ORDER BY A;
SELECT 'DT3', A FROM DT3 ORDER BY A;
SELECT 'DT4', A, S, C FROM DT4 ORDER BY A;
SQL
}
work_v=$(valq "$WORK")
check "the engine SELECTs old + new rows with computed values from fc's file" \
    "$work_v" "$(valq "$REF")"
case "$work_v" in *"3000000000"*) echo "OK   vacuous-guard: a beyond-INT32 value went through the widened column" ;;
    *) echo "DIFF vacuous wide"; echo "     $work_v"; fail=1 ;; esac
# the STALE computed type is live behavior: C stayed a LONG, so reading
# it over the widened BIGINT operand's big value overflows - identically
# on fire-crab's file and the engine's own
staleq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
SELECT C FROM DT3 WHERE A > 2000000000;
SQL
}
work_s=$(staleq "$WORK")
check "reading the stale-typed computed column overflows identically" "$work_s" "$(staleq "$REF")"
case "$work_s" in SQLSTATE*) echo "OK   vacuous-guard: the overflow is a real SQL error (SQLSTATE $work_s)" ;;
    *) echo "DIFF vacuous stale-overflow"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dropcomp-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab altered"
else echo "DIFF gbak backup"; cat /tmp/fc-dropcomp-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dropcomp-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dropcomp-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dropcomp-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
