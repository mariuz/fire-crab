#!/bin/bash
# RDB$FIELD_LENGTH - the byte length of a field, and the RDB$RUNTIME that
# echoes it.
#
# RDB$FIELD_LENGTH is a field's declared BYTE length: 4 for INTEGER, 20 for
# VARCHAR(20), 5 for CHAR(5). It is NOT the storage length a VARYING carries
# on disk - character count plus a two-byte count word (22 for VARCHAR(20))
# - which belongs in the format descriptor. fire-crab had been writing the
# storage length into RDB$FIELD_LENGTH and the matching RDB$RUNTIME
# RSR_field_length tag; the engine writes the byte length in both. No gate
# had compared these against the engine's own values, so the storage length
# had passed (the engine tolerates it - it reads, backs up and restores such
# a table). This gate compares them.
#
# The differential is the engine, three ways, on a table with a VARCHAR, a
# CHAR and a NUMERIC column (the types where declared and storage length
# differ, or where the value is easy to get wrong):
#   1. fire-crab and the engine create the same table on two copies of one
#      database; every column's RDB$FIELD_LENGTH is compared;
#   2. the RDB$RUNTIME blob - which carries RSR_field_length per field - is
#      compared BYTE FOR BYTE (fixing the field length makes fire-crab's
#      runtime byte-identical to the engine's);
#   3. gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-fieldlen.sh [port]
#
# Builds its own scratch databases (one written by fire-crab, one by the
# engine).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4165}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fl-work.fdb"; REF="$D/fc-fl-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF"

DDL="CREATE TABLE T (A INTEGER, B VARCHAR(20), C CHAR(5), D NUMERIC(9,2), E BIGINT, F VARCHAR(1))"

# the engine's copy: it writes the table itself
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL;
COMMIT;
EOF
# fire-crab's copy: an empty database it will write the table into
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fl.log 2>&1 &
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

check "fire-crab creates the table" "$(node_run "$DDL")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. RDB$FIELD_LENGTH per column ------------------------------------
flq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(rf.RDB$FIELD_NAME)||'|len='||f.RDB$FIELD_LENGTH||'|clen='||COALESCE(f.RDB$CHARACTER_LENGTH,-9)
  FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE
  WHERE rf.RDB$RELATION_NAME = 'T' ORDER BY rf.RDB$FIELD_POSITION;
SQL
}
work_fl=$(flq "$WORK")
check "every column's RDB\$FIELD_LENGTH matches the engine" "$work_fl" "$(flq "$REF")"
case "$work_fl" in
    *"B|len=20|clen=20"*"C|len=5|clen=5"*"F|len=1|clen=1"*)
        echo "OK   VARCHAR(20)=20, CHAR(5)=5, VARCHAR(1)=1 (byte length, not the +2 storage length)" ;;
    *) echo "DIFF the field-length comparison was vacuous or wrong"; echo "     $work_fl"; fail=1 ;;
esac

# --- 2. the RDB$RUNTIME blob, byte for byte ----------------------------
rtq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$bid" ] || { echo "(no runtime blob)"; return; }
    rm -f /tmp/fc-fl-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-fl-rt.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-fl-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "the RDB\$RUNTIME blob matches the engine's byte for byte" "$(rtq "$WORK")" "$(rtq "$REF")"

# --- 3. gfix -----------------------------------------------------------
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
