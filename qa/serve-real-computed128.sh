#!/bin/bash
# COMPUTED BY columns with an INT128-width result - the promote case the
# computed slices (inc 108/109) refused. The engine's dtype-driven rule
# (the same one the select-list expressions follow): `*` and `/` promote
# to INT128 as soon as either operand ranks INT64 or wider, `+`/`-` only
# widen when an operand already IS INT128; the catalog row is field type
# 26, length 16, precision 38 (probed).
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine run the same DDL on two copies (CREATE
#      TABLE with the promote matrix, ALTER ADD on it, and ALTER ADD over
#      an ENGINE-created INT128 column - a type fire-crab cannot declare
#      itself); every (type|sub|scale|precision|length) row matches;
#   2. the RDB$FORMATS descriptors match byte for byte;
#   3. the engine EVALUATES fire-crab's computed columns - including a
#      product past i64 that only an INT128 evaluation can hold;
#   4. fire-crab SERVES the computed values over the wire (announced
#      INT128), matching isql on the same file;
#   5. gbak round trip and gfix -v -full.
#
#   qa/serve-real-computed128.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4284}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-c128-work.fdb"; REF="$D/fc-c128-ref.fdb"
FBK="$D/fc-c128-work.fbk"; RST="$D/fc-c128-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# the engine lays the INT128 base table on BOTH copies (fire-crab does
# not declare INT128 storage itself); fire-crab then runs the computed
# DDL on the work copy, the engine the identical list on the ref
for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE W (I INT128);
COMMIT;
EOF
done

DDL=(
  "CREATE TABLE CT (A INTEGER, B BIGINT, X1 COMPUTED BY (B*2), X2 COMPUTED BY (B/2), X3 COMPUTED BY ((A+B)*2), X6 COMPUTED BY (B+B), X7 COMPUTED BY (A*B))"
  "ALTER TABLE CT ADD X8 COMPUTED BY (B*3)"
  "ALTER TABLE W ADD XI COMPUTED BY (I+1)"
  "ALTER TABLE W ADD XJ COMPUTED BY (I)"
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-c128.log 2>&1 &
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
node_rows() { # rows only, values joined by |
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          for(const row of (r||[]))
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
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

for s in "${DDL[@]}"; do
    check "fire-crab: ${s:0:46}..." "$(retry node_ddl "$s")" "OK"
done

# --- fire-crab SERVES the computed columns (announced INT128) ---------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO CT (A, B) VALUES (3, 4000000000);
INSERT INTO CT (A, B) VALUES (NULL, NULL);
INSERT INTO W (I) VALUES (10);
COMMIT;
SQL
fcv=$(retry node_rows 'SELECT X1, X2, X3, X6, X7, X8 FROM CT WHERE B = 4000000000')
check "fc serves the wide computed row over the wire" \
      "$fcv" "8000000000|2000000000|8000000006|8000000000|12000000000|12000000000"
fcn=$(retry node_rows 'SELECT X1, X7 FROM CT WHERE B IS NULL')
check "NULL base row: computed results stay NULL" "$fcn" "<null>|<null>"
fcw=$(retry node_rows 'SELECT XI, XJ FROM W')
check "fc serves computed-over-INT128 (XI = I+1, XJ = I)" "$fcw" "11|10"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the engine runs the identical DDL + rows on the ref -----------
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$(printf '%s;\nCOMMIT;\n' "${DDL[@]}")
INSERT INTO CT (A, B) VALUES (3, 4000000000);
INSERT INTO CT (A, B) VALUES (NULL, NULL);
INSERT INTO W (I) VALUES (10);
COMMIT;
EOF

catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(rf.RDB$RELATION_NAME)||'.'||TRIM(rf.RDB$FIELD_NAME)||'|'||f.RDB$FIELD_TYPE
       ||'|'||COALESCE(f.RDB$FIELD_SUB_TYPE,-99)||'|'||f.RDB$FIELD_SCALE
       ||'|'||COALESCE(f.RDB$FIELD_PRECISION,-99)||'|'||f.RDB$FIELD_LENGTH
       ||'|'||CAST(f.RDB$COMPUTED_SOURCE AS VARCHAR(60))
FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE
WHERE rf.RDB$RELATION_NAME IN ('CT','W') AND f.RDB$COMPUTED_SOURCE IS NOT NULL ORDER BY 1;
SQL
}
work_c=$(catq "$WORK")
check "every computed column's catalog row matches the engine" "$work_c" "$(catq "$REF")"
case "$work_c" in
    *"CT.X1|26|0|0|38|16|(B*2)"*"CT.X6|16|0|0|18|8|(B+B)"*"W.XJ|26|0|0|38|16|(I)"*)
        echo "OK   the teeth bite: X1 promoted to 26/38/16, X6 stays INT64, bare INT128 ref keeps 26" ;;
    *) echo "DIFF the catalog comparison was vacuous"; echo "     $work_c"; fail=1 ;;
esac

# --- 2. RDB$FORMATS descriptors byte for byte --------------------------
fmtq() { # <file> <relname> <formatno>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT fmt.RDB\$DESCRIPTOR FROM RDB\$FORMATS fmt
  JOIN RDB\$RELATIONS r ON r.RDB\$RELATION_ID = fmt.RDB\$RELATION_ID
 WHERE r.RDB\$RELATION_NAME = '$2' AND fmt.RDB\$FORMAT = $3;
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-c128-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-c128-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-c128-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "CT format 1 descriptors match byte for byte" "$(fmtq "$WORK" CT 1)" "$(fmtq "$REF" CT 1)"
check "CT format 2 (post-ALTER) descriptors match byte for byte" "$(fmtq "$WORK" CT 2)" "$(fmtq "$REF" CT 2)"
check "W format 3 (two computed ALTERs) descriptors match byte for byte" "$(fmtq "$WORK" W 3)" "$(fmtq "$REF" W 3)"

# --- 3. the engine EVALUATES fc's computed columns ---------------------
evq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
INSERT INTO CT (A, B) VALUES (1, 6000000000000000000);
COMMIT;
SET HEADING OFF;
SELECT 'CT|'||X1||'|'||X2||'|'||X3||'|'||X6||'|'||X7||'|'||X8 FROM CT WHERE B = 4000000000;
SELECT 'BIG|'||X1||'|'||X8 FROM CT WHERE A = 1;
SELECT 'W|'||XI||'|'||XJ FROM W;
SQL
}
check "the engine evaluates fc's computed cols - incl a past-i64 product" \
      "$(evq "$WORK")" "$(evq "$REF")"
case "$(evq "$WORK" 2>/dev/null; "$ISQL" -q -b -user "$U" -pas "$P" "$WORK" <<< "SET HEADING OFF; SELECT 'BIG|'||X1 FROM CT WHERE A = 1 ROWS 1;" 2>/dev/null | strip)" in
    *"BIG|12000000000000000000"*) echo "OK   the big product really is past i64 (12000000000000000000)" ;;
    *) echo "DIFF the past-i64 check was vacuous"; fail=1 ;;
esac

# --- 4. gbak and gfix ---------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-c128-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-c128-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-c128-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-c128-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-c128-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
