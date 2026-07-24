#!/bin/bash
# CREATE DOMAIN ... DEFAULT - a default that lives on the domain itself.
#
# A domain's DEFAULT is two blobs on the domain's own RDB$FIELDS row (the same
# relation the domain itself is a row of): RDB$DEFAULT_SOURCE, the text
# ("DEFAULT 42", subtype 1, charset 4 like a description), and
# RDB$DEFAULT_VALUE, the BLR - the same literal BLR a column default uses
# (blr_long for an integer, blr_text2 for a string, blr_null for DEFAULT NULL),
# but written into RDB$FIELDS (2) rather than RDB$RELATION_FIELDS (5).
#
# fire-crab does not yet declare a table column with a user domain type, so the
# end-to-end proof runs the other way: fire-crab writes the domain, and the
# ENGINE - creating a table that uses that domain, on fire-crab's own file -
# inherits the default on an insert that omits the column. That the engine
# resolves fire-crab's domain default into a real row is the strongest check.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine create the same domains on two copies; every
#      RDB$DEFAULT_SOURCE is compared;
#   2. each RDB$DEFAULT_VALUE BLR is compared BYTE FOR BYTE (int, string, and
#      DEFAULT NULL), and one source blob byte for byte (charset/framing);
#   3. the engine INHERITS fire-crab's domain default: a table it creates on
#      fire-crab's file using the domain takes the default on insert;
#   4. a domain with no default has neither source nor value on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-domaindefault.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4187}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dd-work.fdb"; REF="$D/fc-dd-ref.fdb"
FBK="$D/fc-dd-work.fbk"; RST="$D/fc-dd-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DI="CREATE DOMAIN DOM_I AS INTEGER DEFAULT 42"
DS="CREATE DOMAIN DOM_S AS VARCHAR(10) DEFAULT 'hi'"
DN="CREATE DOMAIN DOM_N AS INTEGER DEFAULT NULL"
DP="CREATE DOMAIN DOM_P AS INTEGER"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DI; $DS; $DN; $DP;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dd.log 2>&1 &
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

for q in "$DI" "$DS" "$DN" "$DP"; do
    check "fire-crab: $q" "$(node_run "$q")" "OK"
done
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the domain default sources -------------------------------------
srcq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DEFAULT_SOURCE AS VARCHAR(30)),'<none>')
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME LIKE 'DOM\_%' ESCAPE '\' ORDER BY RDB$FIELD_NAME;
SQL
}
work_src=$(srcq "$WORK")
check "every domain's RDB\$DEFAULT_SOURCE matches the engine" "$work_src" "$(srcq "$REF")"
case "$work_src" in
    *"DOM_I|DEFAULT 42"*"DOM_N|DEFAULT NULL"*"DOM_P|<none>"*"DOM_S|DEFAULT 'hi'"*)
        echo "OK   the sources carry int/string/NULL defaults; the plain domain has none" ;;
    *) echo "DIFF the source comparison was vacuous or wrong"; echo "     $work_src"; fail=1 ;;
esac

# --- 2. the DEFAULT_VALUE BLR + one source blob, byte for byte ----------
blob_bytes() { # <file> <domain-name> <field>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT $3 FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME='$2';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dd-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-dd-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dd-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
for d in DOM_I DOM_S DOM_N; do
    check "$d: RDB\$DEFAULT_VALUE BLR byte for byte" \
          "$(blob_bytes "$WORK" "$d" 'RDB$DEFAULT_VALUE')" "$(blob_bytes "$REF" "$d" 'RDB$DEFAULT_VALUE')"
done
check "DOM_S: RDB\$DEFAULT_SOURCE blob byte for byte (charset/framing)" \
      "$(blob_bytes "$WORK" DOM_S 'RDB$DEFAULT_SOURCE')" "$(blob_bytes "$REF" DOM_S 'RDB$DEFAULT_SOURCE')"
check "DOM_P (no default) has no RDB\$DEFAULT_VALUE" "$(blob_bytes "$WORK" DOM_P 'RDB$DEFAULT_VALUE')" "(none)"

# --- 3. the engine INHERITS fire-crab's domain default -----------------
# the engine, on fire-crab's own file, creates a table using the domain and
# inserts a row that omits the column - it must take the domain's default
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
CREATE TABLE T (X DOM_I, Y INTEGER);
COMMIT;
INSERT INTO T (Y) VALUES (1);
COMMIT;
SQL
inherited=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(CAST(X AS VARCHAR(6)),'null') FROM T;
SQL
)
check "the engine inherits fire-crab's domain default on a column that omits it" "$inherited" "42"

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dd-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dd-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dd-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dd-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dd-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
