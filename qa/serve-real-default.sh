#!/bin/bash
# Column DEFAULT - the literal a column takes when a row omits it.
#
# A column DEFAULT is two catalog writes on RDB$RELATION_FIELDS (not the
# auto-domain): RDB$DEFAULT_SOURCE, the text ("DEFAULT 0"), and
# RDB$DEFAULT_VALUE, the BLR that computes the value. For a literal the BLR
# is `blr_version5, blr_literal, <typed literal>, blr_eoc` - blr_long with a
# 4-byte value for any integer (probe: a SMALLINT and a BIGINT default both
# carry blr_long), blr_text2 for a string. fire-crab emits that BLR, and the
# source text carries charset 4 like a description.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine create the same table on two copies; every
#      column's RDB$DEFAULT_SOURCE is compared;
#   2. each RDB$DEFAULT_VALUE BLR is compared BYTE FOR BYTE, and the source
#      blob for one column byte for byte (charset and framing);
#   3. the engine APPLIES fire-crab's defaults: a row that omits the columns
#      takes each default value;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-default.sh [port]
#
# Builds its own scratch databases (one written by fire-crab, one by the
# engine).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4169}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-def-work.fdb"; REF="$D/fc-def-ref.fdb"
FBK="$D/fc-def-work.fbk"; RST="$D/fc-def-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DDL="CREATE TABLE T (A INTEGER DEFAULT 0, B VARCHAR(10) DEFAULT 'hi there', C INTEGER DEFAULT 42, N INTEGER DEFAULT -3, S SMALLINT DEFAULT 5, D INTEGER)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-def.log 2>&1 &
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

check "fire-crab creates the table with defaults" "$(node_run "$DDL")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the default sources --------------------------------------------
srcq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DEFAULT_SOURCE AS VARCHAR(30)),'<none>')
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_src=$(srcq "$WORK")
check "every column's RDB\$DEFAULT_SOURCE matches the engine" "$work_src" "$(srcq "$REF")"
case "$work_src" in
    *"A|DEFAULT 0"*"B|DEFAULT 'hi there'"*"N|DEFAULT -3"*"D|<none>"*)
        echo "OK   the sources carry the literals (int, string with a space, negative); D has none" ;;
    *) echo "DIFF the source comparison was vacuous or wrong"; echo "     $work_src"; fail=1 ;;
esac

# --- 2. the DEFAULT_VALUE BLR + the source blob, byte for byte ----------
blob_bytes() { # <file> <col> <column-name>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT $3 FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME='T' AND RDB\$FIELD_NAME='$2';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-def-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-def-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-def-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
for c in A B C N S; do
    check "$c: RDB\$DEFAULT_VALUE BLR byte for byte" \
          "$(blob_bytes "$WORK" "$c" 'RDB$DEFAULT_VALUE')" "$(blob_bytes "$REF" "$c" 'RDB$DEFAULT_VALUE')"
done
check "B: RDB\$DEFAULT_SOURCE blob byte for byte (charset/framing)" \
      "$(blob_bytes "$WORK" B 'RDB$DEFAULT_SOURCE')" "$(blob_bytes "$REF" B 'RDB$DEFAULT_SOURCE')"

# --- 3. the engine APPLIES fire-crab's defaults ------------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (D) VALUES (1);
COMMIT;
SQL
applied=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A||'|'||TRIM(B)||'|'||C||'|'||N||'|'||S FROM T WHERE D = 1;
SQL
)
check "the engine applied fire-crab's defaults on INSERT" "$applied" "0|hi there|42|-3|5"

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-def-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-def-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-def-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-def-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-def-restore.log | head; fail=1
fi
check "the restored default sources match fire-crab's" "$(srcq "$RST")" "$(srcq "$WORK")"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
