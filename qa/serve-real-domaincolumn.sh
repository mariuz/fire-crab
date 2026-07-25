#!/bin/bash
# A table column typed by a user domain - CREATE TABLE T (X DOM).
#
# fire-crab could create the domain and comment/alter it, but not yet USE it as
# a column type. A domain column is not an auto-domain: its RDB$FIELD_SOURCE is
# the domain's own name (no new RDB$FIELDS row is written for it), and the
# per-table auto-domain counter (RDB$<n>) skips it. It carries NEITHER a
# RDB$NULL_FLAG nor a default on its RDB$RELATION_FIELDS row - those stay on the
# domain - and its RDB$COLLATION_ID is NULL (a built-in column's is 0). The
# domain's type fills the format descriptor, and the domain's DEFAULT and
# NOT NULL are folded into the relation's RDB$RUNTIME, so the engine applies
# and enforces them.
#
# The differential is the engine, six ways:
#   1. fire-crab and the engine create the same domains and table on two copies;
#      the RDB$FORMATS descriptor blob is compared BYTE FOR BYTE (the domain
#      types fill it);
#   2. the rebuilt RDB$RUNTIME is compared byte for byte (inherited default and
#      not-null land there);
#   3. every RDB$RELATION_FIELDS row is compared (field source = domain name,
#      no null flag / default / collation on a domain column);
#   4. exactly one auto-domain RDB$<n> is written (for the built-in column);
#   5. the engine applies the inherited default and enforces the inherited
#      NOT NULL on insert;
#   6. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-domaincolumn.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4210}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dcol-work.fdb"; REF="$D/fc-dcol-ref.fdb"
FBK="$D/fc-dcol-work.fbk"; RST="$D/fc-dcol-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DOMS="CREATE DOMAIN DOM_I AS INTEGER DEFAULT 42; CREATE DOMAIN DOM_V AS VARCHAR(6) NOT NULL; CREATE DOMAIN DOM_P AS INTEGER;"
DDL="CREATE TABLE T (X DOM_I, V DOM_V, Y INTEGER, Z DOM_P)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DOMS $DDL;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DOMS
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dcol.log 2>&1 &
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

check "fire-crab creates a table with domain columns" "$(node_run "$DDL")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the format descriptor, byte for byte --------------------------
fmtq() { # <file>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT f.RDB$DESCRIPTOR FROM RDB$FORMATS f JOIN RDB$RELATIONS r ON r.RDB$RELATION_ID = f.RDB$RELATION_ID
  WHERE r.RDB$RELATION_NAME = 'T' ORDER BY f.RDB$FORMAT DESC ROWS 1;
SQL
)
    [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dcol-fmt.bin
    printf 'BLOBDUMP %s /tmp/fc-dcol-fmt.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dcol-fmt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "the RDB\$FORMATS descriptor matches the engine (domain types fill it)" "$(fmtq "$WORK")" "$(fmtq "$REF")"

# --- 2. the runtime, byte for byte ------------------------------------
rtq() { # <file>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dcol-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-dcol-rt.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dcol-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "the RDB\$RUNTIME matches the engine (inherited default + not-null)" "$(rtq "$WORK")" "$(rtq "$REF")"

# --- 3. every RDB$RELATION_FIELDS row ---------------------------------
rfq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|src='||TRIM(RDB$FIELD_SOURCE)
       ||'|nf='||COALESCE(CAST(RDB$NULL_FLAG AS VARCHAR(2)),'-')
       ||'|df='||TRIM(CASE WHEN RDB$DEFAULT_VALUE IS NULL THEN '-' ELSE 'set' END)
       ||'|cid='||COALESCE(CAST(RDB$COLLATION_ID AS VARCHAR(3)),'NULL')
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_rf=$(rfq "$WORK")
check "every RDB\$RELATION_FIELDS row matches the engine" "$work_rf" "$(rfq "$REF")"
case "$work_rf" in
    *"X|src=DOM_I|nf=-|df=-|cid=NULL"*"Y|src=RDB\$1|"*"|cid=0"*)
        echo "OK   a domain column's source is the domain (no flag/default/collation); the built-in has cid 0" ;;
    *) echo "DIFF the RF comparison was vacuous or wrong"; echo "     $work_rf"; fail=1 ;;
esac

# --- 4. exactly one auto-domain (for the built-in column Y) -----------
autq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$FIELDS WHERE RDB$FIELD_NAME STARTING WITH 'RDB$' AND RDB$SYSTEM_FLAG=0;
SQL
}
check "exactly one auto-domain RDB\$<n> is written (for the built-in column)" "$(autq "$WORK")" "$(autq "$REF")"

# --- 5. the engine applies/enforces the inherited constraints ---------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (V, Y) VALUES ('hi', 1);
COMMIT;
SQL
row=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(CAST(X AS VARCHAR(5)),'n')||'|'||TRIM(V)||'|'||Y FROM T;
SQL
)
check "the engine applies the domain default (X=42) on a row that omits X" "$row" "42|hi|1"
enf=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO T (Y) VALUES (2);
SQL
)
case "$enf" in *[Vv]alidation*|*"*** null ***"*) echo "OK   the engine enforces the domain NOT NULL (V required)" ;;
    *) echo "DIFF the engine did not enforce the domain NOT NULL"; echo "     $enf"; fail=1 ;; esac

# --- 6. gbak and gfix -------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dcol-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dcol-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dcol-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dcol-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dcol-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
