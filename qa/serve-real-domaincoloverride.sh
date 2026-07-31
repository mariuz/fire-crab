#!/bin/bash
# A domain column that overrides the domain - X DOM NOT NULL / X DOM DEFAULT v.
#
# A column typed by a domain may still carry its own NOT NULL or DEFAULT, which
# override (or add to) the domain's. A column-level NOT NULL sets the column's
# RDB$RELATION_FIELDS.RDB$NULL_FLAG and writes an INTEG_<n> constraint - exactly
# as a built-in column's does - and folds NOT NULL into the runtime. A
# column-level DEFAULT writes the column's own RDB$DEFAULT_SOURCE/VALUE and its
# BLR is the one in the runtime, in place of the domain's. A plain domain column
# (neither) inherits both from the domain. The column-level path is the same one
# a built-in column uses; only the RDB$FIELD_SOURCE (the domain) and the missing
# RDB$COLLATION_ID differ.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine create the same domains and table on two copies;
#      every RDB$RELATION_FIELDS row is compared (null flag, default source);
#   2. the RDB$RUNTIME is compared BYTE FOR BYTE (override default wins, the
#      plain column inherits, the NOT NULL column carries the not-null marker);
#   3. the INTEG NOT NULL constraint for the domain column matches the engine;
#   4. the engine applies each: a row that gives only the NOT NULL column takes
#      the override default and the inherited default in the other two;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-domaincoloverride.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4213}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dcov-work.fdb"; REF="$D/fc-dcov-ref.fdb"
FBK="$D/fc-dcov-work.fbk"; RST="$D/fc-dcov-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DOMS="CREATE DOMAIN DOM_I AS INTEGER DEFAULT 42; CREATE DOMAIN DOM_P AS INTEGER;"
DDL="CREATE TABLE T (A DOM_P NOT NULL, B DOM_I DEFAULT 7, C DOM_I, Y INTEGER)"

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

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dcov.log 2>&1 &
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

check "fire-crab creates domain columns with overrides" "$(node_run "$DDL")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RF rows ---------------------------------------------------
rfq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|src='||TRIM(RDB$FIELD_SOURCE)
       ||'|nf='||COALESCE(CAST(RDB$NULL_FLAG AS VARCHAR(2)),'-')
       ||'|dsrc='||TRIM(COALESCE(CAST(RDB$DEFAULT_SOURCE AS VARCHAR(12)),'-'))
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_rf=$(rfq "$WORK")
check "every RDB\$RELATION_FIELDS row matches the engine" "$work_rf" "$(rfq "$REF")"
case "$work_rf" in
    *"A|src=DOM_P|nf=1|dsrc=-"*"B|src=DOM_I|nf=-|dsrc=DEFAULT 7"*"C|src=DOM_I|nf=-|dsrc=-"*)
        echo "OK   A has the column NOT NULL, B its own default, C inherits (no flag/default)" ;;
    *) echo "DIFF the RF comparison was vacuous or wrong"; echo "     $work_rf"; fail=1 ;;
esac

# --- 2. the runtime, byte for byte ------------------------------------
rtq() { # <file>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dcov-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-dcov-rt.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dcov-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "the RDB\$RUNTIME matches the engine byte for byte (override wins, plain inherits)" "$(rtq "$WORK")" "$(rtq "$REF")"

# --- 3. the INTEG NOT NULL constraint ---------------------------------
ccq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$CONSTRAINT_NAME)||'->'||TRIM(RDB$TRIGGER_NAME)
  FROM RDB$CHECK_CONSTRAINTS WHERE RDB$CONSTRAINT_NAME STARTING WITH 'INTEG' ORDER BY 1;
SQL
}
check "the INTEG NOT NULL constraint for the domain column matches the engine" "$(ccq "$WORK")" "$(ccq "$REF")"

# --- 4. the engine applies each ---------------------------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (A) VALUES (1);
COMMIT;
SQL
row=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A||'|'||COALESCE(CAST(B AS VARCHAR(5)),'n')||'|'||COALESCE(CAST(C AS VARCHAR(5)),'n') FROM T;
SQL
)
check "the engine applies the override (B=7) and the inherited default (C=42)" "$row" "1|7|42"
enf=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO T (B) VALUES (9);
SQL
)
case "$enf" in *[Vv]alidation*|*"*** null ***"*) echo "OK   the engine enforces the column NOT NULL (A required)" ;;
    *) echo "DIFF the engine did not enforce the column NOT NULL"; echo "     $enf"; fail=1 ;; esac

# --- 5. gbak and gfix -------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dcov-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dcov-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dcov-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dcov-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dcov-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
