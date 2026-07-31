#!/bin/bash
# A column DEFAULT survives an ALTER TABLE.
#
# ALTER TABLE ADD rebuilds a relation's RDB$RUNTIME from its current fields
# (the engine's DSQL layer resolves columns through it). A column's DEFAULT
# lives in that runtime as an RSR_default_value entry - the entry the engine
# actually applies the default from - so the rebuild must re-emit it or the
# ALTER silently drops the default, leaving every earlier column's default
# inert.
#
# The differential is the engine, three ways:
#   1. fire-crab and the engine each create a table with a default and then
#      ALTER it to add a column, on two copies; the RDB$RUNTIME blob is
#      compared BYTE FOR BYTE (the default entry survives the rebuild);
#   2. the engine applies the surviving default: a row that omits the
#      defaulted column still takes its default value;
#   3. gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-alterdefault.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4170}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-ad-work.fdb"; REF="$D/fc-ad-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF"

C1="CREATE TABLE T (A INTEGER DEFAULT 7, C INTEGER DEFAULT 42, D INTEGER)"
C2="ALTER TABLE T ADD E INTEGER"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$C1; $C2;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ad.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
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

check "fire-crab creates the table with defaults" "$(node_run "$C1")" "OK"
check "fire-crab ALTER TABLE ADD (rebuilds the runtime)" "$(node_run "$C2")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. RDB$RUNTIME survives the rebuild, byte for byte ----------------
rtq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-ad-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-ad-rt.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-ad-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "MASTER's RDB\$RUNTIME matches the engine byte for byte after the ALTER" "$(rtq "$WORK")" "$(rtq "$REF")"
# teeth: the runtime really carries the RSR_default_value entry (tag 6, then the default BLR 5 21)
case "$(rtq "$WORK")" in
    *" 6 5 21 "*) echo "OK   the runtime still carries the RSR_default_value entries after the rebuild" ;;
    *) echo "DIFF the runtime lost the default entry"; fail=1 ;;
esac

# --- 2. the default still applies --------------------------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (D) VALUES (1);
COMMIT;
SQL
applied=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A||'|'||C FROM T WHERE D = 1;
SQL
)
check "the defaults still apply after the ALTER (A=7, C=42)" "$applied" "7|42"

# --- 3. gfix -----------------------------------------------------------
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
