#!/bin/bash
# COMPUTED BY columns - a column that is an expression, not storage.
#
# A computed column's catalog: an auto-domain RDB$FIELDS row carrying the
# expression twice (RDB$COMPUTED_SOURCE verbatim text + RDB$COMPUTED_BLR
# compiled), the RESULT type inferred by the engine's dialect-3 rules
# (+/- of exact ints -> BIGINT precision 18; * and / promote an INT64
# operand to INT128 - which fire-crab refuses rather than writes; a bare
# field keeps its type but gains a real precision), RDB$UPDATE_FLAG 0 on
# the RDB$RELATION_FIELDS row, a format descriptor with the result type
# at OFFSET 0 (no storage - the offset walk skips it, probed with a
# computed column in the MIDDLE of a table), and an RSR_computed_blr(4)
# segment in RDB$RUNTIME between the length and position segments.
#
# The differential is the engine, six ways:
#   1. fire-crab and the engine create the same four computed tables on
#      two copies; every computed field's type/length/scale/sub_type/
#      precision, source text, BLR hex and update flag are compared;
#   2. the RDB$FORMATS descriptor blob is compared BYTE FOR BYTE (TF has
#      the computed column mid-table - the offset-walk teeth);
#   3. the RDB$RUNTIME blob is compared BYTE FOR BYTE (TC);
#   4. the ENGINE uses fire-crab's tables: inserts rows into the raw file
#      and SELECTs the computed columns - values equal the reference,
#      including NULL propagation; naming a computed column in an INSERT
#      errors on both files alike;
#   5. fire-crab SERVES the computed column itself: node-firebird selects
#      it (evaluated per row from the stored source) and an INSERT with
#      no column list excludes it, exactly like the engine's;
#   6. gbak round trip and gfix -v -full on fire-crab's raw file.
# fire-crab must also REFUSE what it cannot write faithfully: an INT128
# result (BIGINT * 2) errors, never a wrong type.
#
#   qa/serve-real-computed.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4241}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-comp-work.fdb"; REF="$D/fc-comp-ref.fdb"
FBK="$D/fc-comp-work.fbk"; RST="$D/fc-comp-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

T1="CREATE TABLE TC (A INTEGER, B INTEGER, C COMPUTED BY (A+B))"
T2="CREATE TABLE TD (S SMALLINT, D COMPUTED BY (S))"
T3="CREATE TABLE TF (A INTEGER, C COMPUTED BY (A+1), B BIGINT)"
T4="CREATE TABLE TG (A INTEGER, W COMPUTED BY (5), E COMPUTED BY (A*2), F GENERATED ALWAYS AS (A-1))"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$T1; $T2; $T3; $T4;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-computed.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_once() { # <query> -> OK / ERR <msg> / row values joined by |
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

check "fire-crab: computed from two columns (A+B)" "$(node_run "$T1")" "OK"
check "fire-crab: computed passthrough of a SMALLINT" "$(node_run "$T2")" "OK"
check "fire-crab: computed column mid-table" "$(node_run "$T3")" "OK"
check "fire-crab: literal, *, GENERATED ALWAYS AS spellings" "$(node_run "$T4")" "OK"
# an INT128 result (BIGINT * 2) promotes since inc 121 (deep
# differential: serve-real-computed128) - here just prove it creates
case "$(node_run 'CREATE TABLE TH (B BIGINT, X COMPUTED BY (B*2))')" in
    OK) echo "OK   an INT128 result (BIGINT * 2) now CREATES (promoted, inc 121)" ;;
    *) echo "DIFF INT128 promotion"; fail=1 ;; esac

# fire-crab serves the computed columns itself (evaluated per row from
# the stored source text), and its implicit INSERT list excludes them
check "fire-crab: INSERT with no column list skips computed" \
    "$(node_run 'INSERT INTO TC VALUES (30, 12)')" "OK"
check "fire-crab: SELECT of a computed column evaluates it" \
    "$(node_run 'SELECT A, B, C FROM TC')" "30|12|42"
check "fire-crab: writes a row the computed mid-table" \
    "$(node_run 'INSERT INTO TF (A, B) VALUES (10, 100)')" "OK"
check "fire-crab: SELECT * includes the computed column, mid-table" \
    "$(node_run 'SELECT * FROM TF')" "10|11|100"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the same engine-side inserts on both files; computed values must match.
# The reference also gets the rows node-firebird wrote through fire-crab
# above, so the two files hold the same data.
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO TC (A, B) VALUES (1, 2);
INSERT INTO TC (A) VALUES (7);
INSERT INTO TD (S) VALUES (-3);
INSERT INTO TG (A) VALUES (6);
COMMIT;
SQL
}
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO TC (A, B) VALUES (30, 12);
INSERT INTO TF (A, B) VALUES (10, 100);
COMMIT;
SQL
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*) echo "DIFF engine inserts into fc's tables"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine inserts into fire-crab's computed tables" ;; esac

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(rf.RDB$RELATION_NAME)||'.'||TRIM(rf.RDB$FIELD_NAME)||'|'||f.RDB$FIELD_TYPE||'|'||f.RDB$FIELD_LENGTH||'|'||f.RDB$FIELD_SCALE||'|'||f.RDB$FIELD_SUB_TYPE||'|'||f.RDB$FIELD_PRECISION||'|'||rf.RDB$UPDATE_FLAG||'|'||CAST(f.RDB$COMPUTED_SOURCE AS VARCHAR(60))||'|'||CAST(CAST(f.RDB$COMPUTED_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(120) CHARACTER SET OCTETS)
FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE
WHERE rf.RDB$RELATION_NAME IN ('TC','TD','TF','TG') AND f.RDB$COMPUTED_BLR IS NOT NULL
ORDER BY rf.RDB$RELATION_NAME, rf.RDB$FIELD_POSITION;
SQL
}
work_c=$(catq "$WORK")
check "every computed field's type/precision/source/BLR/update-flag matches the engine" \
    "$work_c" "$(catq "$REF")"
# the OCTETS cast makes isql print each row as hex; TC.C's tail decodes
# to `(A+B)|` (28412B42297C) followed by the probed BLR bytes
case "$work_c" in *"28412B42297C052217000141170001424C"*)
    echo "OK   vacuous-guard: TC.C carries source (A+B) and the probed INT64 BLR" ;;
    *) echo "DIFF vacuous"; echo "     $work_c"; fail=1 ;; esac

# format descriptor blobs, byte for byte (TF: computed mid-table)
fmtq() { # <db> <table> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT f.RDB\$DESCRIPTOR FROM RDB\$FORMATS f JOIN RDB\$RELATIONS r ON r.RDB\$RELATION_ID = f.RDB\$RELATION_ID WHERE r.RDB\$RELATION_NAME='$2';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-comp-fmt-$3.bin"
    printf 'BLOBDUMP %s /tmp/fc-comp-fmt-%s.bin;\n' "$b" "$3" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-comp-fmt-$3.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "TF's format descriptor matches byte for byte (computed at offset 0, walk skips it)" \
    "$(fmtq "$WORK" TF w)" "$(fmtq "$REF" TF r)"
check "TC's format descriptor matches byte for byte" \
    "$(fmtq "$WORK" TC w2)" "$(fmtq "$REF" TC r2)"

# the RDB$RUNTIME blob, byte for byte (RSR_computed_blr placement)
rtq() { # <db> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB$RUNTIME FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME='TC';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-comp-rt-$2.bin"
    printf 'BLOBDUMP %s /tmp/fc-comp-rt-%s.bin;\n' "$b" "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-comp-rt-$2.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "TC's RDB\$RUNTIME matches byte for byte (RSR_computed_blr between length and position)" \
    "$(rtq "$WORK" w)" "$(rtq "$REF" r)"

# the engine evaluates fire-crab's computed columns; NULL propagates
valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'TC', A, B, C FROM TC ORDER BY A;
SELECT 'TD', S, D FROM TD;
SELECT 'TF', A, C, B FROM TF;
SELECT 'TG', A, W, E, F FROM TG;
SQL
}
work_v=$(valq "$WORK")
check "the engine SELECTs every computed value from fc's file (incl. NULL propagation)" \
    "$work_v" "$(valq "$REF")"
case "$work_v" in *"<null>"*) echo "OK   vacuous-guard: a NULL operand row is in the comparison" ;;
    *) echo "DIFF vacuous null"; echo "     $work_v"; fail=1 ;; esac

# a computed column refuses INSERT on both files alike (read-only)
roq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
INSERT INTO TC (A, B, C) VALUES (1, 2, 3);
SQL
}
work_ro=$(roq "$WORK")
check "INSERT naming the computed column errors identically" "$work_ro" "$(roq "$REF")"
case "$work_ro" in SQLSTATE*) echo "OK   vacuous-guard: the refusal is a real SQL error" ;;
    *) echo "DIFF vacuous ro"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-comp-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-comp-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-comp-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-comp-restore.log; then echo "OK   gbak RESTORES it (computed catalog survives the round trip)"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-comp-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
