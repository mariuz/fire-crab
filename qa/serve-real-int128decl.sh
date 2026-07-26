#!/bin/bash
# PLAIN INT128 declaration - fire-crab creating INT128 / NUMERIC(19..38)
# / DECIMAL(19..38) storage itself (reading such columns has worked
# since the INT128 wire slice; declaring them was the last gap).
#
# The surface: CREATE TABLE columns (incl DEFAULT - the engine's default
# BLR for an INT128 column is the same blr_literal/blr_long an INTEGER
# gets, probed), ALTER TABLE ADD, ALTER TYPE widening INTEGER -> INT128
# (old rows read back promoted), CREATE DOMAIN NUMERIC(22,2), and the
# literal/parameter DML paths (an i64-ranged value rescales exactly into
# the 16-byte slot). Keys and indexes over INT128 REFUSE - fire-crab's
# key writer has no INT128 itype yet, and it must never write an index
# it would encode wrongly (the engine allows them; conservative).
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine run the same DDL on two copies; every
#      catalog row and every RDB$FORMATS descriptor blob matches byte
#      for byte, the dependent runtime too;
#   2. fire-crab INSERTs (literal + parameter), UPDATEs and reads back
#      its own INT128 rows, old-format rows promoted;
#   3. the engine adopts fc's file: applies fc's DEFAULT, stores the
#      INT128 maximum, which fc then serves via CAST text;
#   4. the index refusals hold;
#   5. gbak round trip and gfix -v -full.
#
#   qa/serve-real-int128decl.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4286}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-i128d-work.fdb"; REF="$D/fc-i128d-ref.fdb"
FBK="$D/fc-i128d-work.fbk"; RST="$D/fc-i128d-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
done

DDL=(
  "CREATE TABLE H (ID INTEGER, I INT128, N NUMERIC(20,2), M DECIMAL(38,4), D INT128 DEFAULT 5)"
  "ALTER TABLE H ADD J INT128"
  "CREATE TABLE H2 (A INTEGER, B VARCHAR(5))"
  "CREATE DOMAIN D128 AS NUMERIC(22,2)"
  "CREATE TABLE H3 (X D128)"
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-i128d.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_q() { # <query> [json params]
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" FC_P="${2:-[]}" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() { # <query> [json params]
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_q "$1" "${2:-[]}")
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

# --- 1. the DDL through fire-crab, DML on its own columns --------------
for s in "${DDL[@]}"; do
    check "fire-crab: ${s:0:46}..." "$(node_run "$s")" "OK"
done
check "fc: rows before the widening ALTER" "$(node_run "INSERT INTO H2 (A, B) VALUES (100, 'x')")" "OK"
check "fc: second pre-ALTER row" "$(node_run "INSERT INTO H2 (A, B) VALUES (200, 'y')")" "OK"
check "fire-crab: ALTER TABLE H2 ALTER A TYPE INT128 (widening)" \
      "$(node_run 'ALTER TABLE H2 ALTER A TYPE INT128')" "OK"
check "fc reads old rows promoted to INT128" \
      "$(node_run 'SELECT A, B FROM H2 ORDER BY A')" "100|x
200|y"
check "fc INSERT into H (INT128 + scaled literals)" \
      "$(node_run "INSERT INTO H (ID, I, N, M, D, J) VALUES (1, 42, 7, 3, 9, 11)")" "OK"
# D omitted: fc applies the INT128 DEFAULT 5 itself (the insertdefault
# slice), exactly as the engine mirror below does
check "fc INSERT with a PARAMETER into INT128 (DEFAULT fills D)" \
      "$(node_run 'INSERT INTO H (ID, I) VALUES (2, ?)' '[4000000000]')" "OK"
check "fc UPDATE SET on an INT128 column" \
      "$(node_run 'UPDATE H SET I = 77 WHERE ID = 2')" "OK"
check "fc reads its INT128 rows back (scaled render via isql below)" \
      "$(node_run 'SELECT ID, I, J FROM H ORDER BY ID')" "1|42|11
2|77|<null>"
# keys/indexes over INT128 refuse - fc has no INT128 index itype yet
# (the ENGINE allows them; a wrongly-encoded index would corrupt, a
# refusal cannot)
case "$(node_run 'CREATE TABLE BAD (K INT128 NOT NULL PRIMARY KEY)')" in
    ERR*) echo "OK   a PRIMARY KEY over INT128 refuses (no itype yet)" ;;
    *) echo "DIFF INT128 PK fence"; fail=1 ;; esac
case "$(node_run 'CREATE INDEX HIX ON H (I)')" in
    ERR*) echo "OK   CREATE INDEX over INT128 refuses" ;;
    *) echo "DIFF INT128 index fence"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. the engine runs the identical DDL + DML on the ref -------------
"$ISQL" -q -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$(printf '%s;\nCOMMIT;\n' "${DDL[@]}")
INSERT INTO H2 (A, B) VALUES (100, 'x');
INSERT INTO H2 (A, B) VALUES (200, 'y');
COMMIT;
ALTER TABLE H2 ALTER A TYPE INT128;
COMMIT;
INSERT INTO H (ID, I, N, M, D, J) VALUES (1, 42, 7, 3, 9, 11);
INSERT INTO H (ID, I) VALUES (2, 4000000000);
UPDATE H SET I = 77 WHERE ID = 2;
COMMIT;
EOF

catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(rf.RDB$RELATION_NAME)||'.'||TRIM(rf.RDB$FIELD_NAME)||'|'||f.RDB$FIELD_TYPE
       ||'|'||COALESCE(f.RDB$FIELD_SUB_TYPE,-99)||'|'||f.RDB$FIELD_SCALE
       ||'|'||COALESCE(f.RDB$FIELD_PRECISION,-99)||'|'||f.RDB$FIELD_LENGTH
FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE
WHERE rf.RDB$RELATION_NAME IN ('H','H2','H3') ORDER BY 1;
SELECT 'FMT|'||TRIM(r.RDB$RELATION_NAME)||'|'||fmt.RDB$FORMAT
FROM RDB$FORMATS fmt JOIN RDB$RELATIONS r ON r.RDB$RELATION_ID = fmt.RDB$RELATION_ID
WHERE r.RDB$RELATION_NAME IN ('H','H2','H3') ORDER BY r.RDB$RELATION_NAME, fmt.RDB$FORMAT;
SQL
}
work_c=$(catq "$WORK")
check "every catalog row and format list matches the engine" "$work_c" "$(catq "$REF")"
case "$work_c" in
    *"H.I|26|0|0|0|16"*"H.N|26|1|-2|20|16"*"H3.X|26|1|-2|22|16"*"FMT|H2|2"*)
        echo "OK   the teeth bite: INT128 26/0/16, NUMERIC(20,2) p20, domain p22, H2 widened" ;;
    *) echo "DIFF the catalog comparison was vacuous"; echo "     $work_c"; fail=1 ;;
esac

blobq() { # <file> <select yielding one blob id>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
$2
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-i128d-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-i128d-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-i128d-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
for spec in "H 1" "H 2" "H2 2" "H3 1"; do
    t=${spec% *}; n=${spec#* }
    q="SELECT fmt.RDB\$DESCRIPTOR FROM RDB\$FORMATS fmt JOIN RDB\$RELATIONS r ON r.RDB\$RELATION_ID = fmt.RDB\$RELATION_ID WHERE r.RDB\$RELATION_NAME = '$t' AND fmt.RDB\$FORMAT = $n;"
    check "$t format $n descriptors match byte for byte" "$(blobq "$WORK" "$q")" "$(blobq "$REF" "$q")"
done
check "H RDB\$RUNTIME (with the INT128 default) matches byte for byte" \
      "$(blobq "$WORK" "SELECT RDB\$RUNTIME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'H';")" \
      "$(blobq "$REF" "SELECT RDB\$RUNTIME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'H';")"

# --- 3. the engine adopts fc's file -------------------------------------
adopt() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
INSERT INTO H (ID, I) VALUES (3, 170141183460469231731687303715884105727);
COMMIT;
SET HEADING OFF;
SELECT 'H|'||ID||'|'||I||'|'||COALESCE(N,-1)||'|'||COALESCE(M,-1)||'|'||D FROM H ORDER BY ID;
SELECT 'H2|'||A||'|'||TRIM(B) FROM H2 ORDER BY A;
SQL
}
aw=$(adopt "$WORK"); ar=$(adopt "$REF")
check "the engine adopts fc's file: fc's DEFAULT applies, max INT128 stored" "$aw" "$ar"
case "$aw" in
    *"H|3|170141183460469231731687303715884105727"*"|5"*)
        echo "OK   row 3 carries the INT128 maximum and fc's DEFAULT 5" ;;
    *) echo "DIFF the adoption check was vacuous"; fail=1 ;;
esac
# fc serves the engine-written maximum via CAST text (dodging the node
# INT128 decode bugs)
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-i128d2.log 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
check "fc serves the engine-written INT128 maximum via CAST text" \
      "$(node_run 'SELECT CAST(I AS VARCHAR(45)) FROM H WHERE ID = 3')" \
      "170141183460469231731687303715884105727"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 4. gbak and gfix ----------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-i128d-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-i128d-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-i128d-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-i128d-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-i128d-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
