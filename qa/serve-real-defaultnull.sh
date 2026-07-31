#!/bin/bash
# Column DEFAULT NULL - stored, and distinct from no default at all.
#
# DEFAULT NULL is not the same catalog state as a column with no default: the
# engine records the intent. RDB$DEFAULT_SOURCE is the text "DEFAULT NULL",
# RDB$DEFAULT_VALUE is the BLR `blr_version5, blr_null, blr_eoc` (5 45 76), and
# - the usual runtime lesson - an RSR_default_value entry carrying that BLR is
# folded into the relation's RDB$RUNTIME (6 5 45 76). A column with no default
# has neither source, value, nor runtime entry. Both apply as NULL, so only the
# catalog and runtime bytes tell them apart.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine create the same table on two copies; every
#      column's RDB$DEFAULT_SOURCE is compared (DEFAULT NULL vs an integer
#      default vs none);
#   2. the DEFAULT NULL column's RDB$DEFAULT_VALUE BLR is compared BYTE FOR
#      BYTE, and the rebuilt RDB$RUNTIME byte for byte (the null entry is
#      there, distinct from the no-default column which has none);
#   3. the engine applies it: an INSERT that omits the columns leaves the
#      DEFAULT NULL and the no-default columns NULL, the integer default set;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-defaultnull.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4185}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dn-work.fdb"; REF="$D/fc-dn-ref.fdb"
FBK="$D/fc-dn-work.fbk"; RST="$D/fc-dn-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DDL="CREATE TABLE T (A INTEGER DEFAULT NULL, B INTEGER DEFAULT 5, C INTEGER)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dn.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

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

check "fire-crab creates the table (DEFAULT NULL, DEFAULT 5, none)" "$(node_run "$DDL")" "OK"
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
    *"A|DEFAULT NULL"*"B|DEFAULT 5"*"C|<none>"*)
        echo "OK   DEFAULT NULL is stored as a source, distinct from the no-default column" ;;
    *) echo "DIFF the source comparison was vacuous or wrong"; echo "     $work_src"; fail=1 ;;
esac

# --- 2. the DEFAULT_VALUE BLR + the rebuilt runtime, byte for byte ------
blob_bytes() { # <file> <column-name> <field>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT $3 FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME='T' AND RDB\$FIELD_NAME='$2';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dn-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-dn-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dn-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_a=$(blob_bytes "$WORK" A 'RDB$DEFAULT_VALUE')
check "A: DEFAULT NULL value BLR byte for byte" "$work_a" "$(blob_bytes "$REF" A 'RDB$DEFAULT_VALUE')"
case "$work_a" in
    "5 45 76") echo "OK   the BLR is blr_version5, blr_null, blr_eoc (5 45 76)" ;;
    *) echo "DIFF the DEFAULT NULL BLR is not 5 45 76"; echo "     $work_a"; fail=1 ;;
esac
# the no-default column really has no value blob (the distinction is real)
check "C (no default) has no RDB\$DEFAULT_VALUE" "$(blob_bytes "$WORK" C 'RDB$DEFAULT_VALUE')" "(none)"

rtq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME='T';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dn-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-dn-rt.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dn-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_rt=$(rtq "$WORK")
check "RDB\$RUNTIME matches the engine byte for byte" "$work_rt" "$(rtq "$REF")"
case "$work_rt" in
    *" 6 5 45 76 "*) echo "OK   the runtime carries RSR_default_value + blr_null (6 5 45 76)" ;;
    *) echo "DIFF the runtime lacks the null default entry"; fail=1 ;;
esac

# --- 3. the engine applies it ------------------------------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T DEFAULT VALUES;
COMMIT;
SQL
applied=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(CAST(A AS VARCHAR(4)),'n')||'|'||COALESCE(CAST(B AS VARCHAR(4)),'n')||'|'||COALESCE(CAST(C AS VARCHAR(4)),'n') FROM T;
SQL
)
check "an INSERT omitting the columns applies the defaults (A NULL, B 5, C NULL)" "$applied" "n|5|n"

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dn-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dn-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dn-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dn-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dn-restore.log | head; fail=1
fi
check "the restored sources match fire-crab's" "$(srcq "$RST")" "$work_src"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
