#!/bin/bash
# COMMENT ON DATABASE - the comment mechanism on the database itself.
#
# COMMENT ON DATABASE has no object name: it writes a description text blob into
# the singleton RDB$DATABASE row's RDB$DESCRIPTION (charset 4 UTF8, like every
# other description), and IS NULL / IS '' clears it. The one row is patched in
# place.
#
# The differential is the engine:
#   1. fire-crab and the engine each comment the database on two copies; the
#      RDB$DATABASE description is read back as text and compared, and the
#      description blob RECORD is compared byte for byte (framing and charset);
#   2. IS NULL and IS '' clear it to NULL on both;
#   3. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-commentdb.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4217}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-cdb-work.fdb"; REF="$D/fc-cdb-ref.fdb"
FBK="$D/fc-cdb-work.fbk"; RST="$D/fc-cdb-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

CMT="COMMENT ON DATABASE IS 'the handbook, it''s great'"
CLR="COMMENT ON DATABASE IS NULL"
CLR2="COMMENT ON DATABASE IS ''"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$CMT;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cdb.log 2>&1 &
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

check "fire-crab COMMENT ON DATABASE (with '' escape)" "$(node_run "$CMT")" "OK"

# --- 1. the text, and the blob record byte for byte -------------------
txtq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(40)),'<null>') FROM RDB$DATABASE;
SQL
}
check "the database comment reads back identical to the engine's" "$(txtq "$WORK")" "$(txtq "$REF")"
check "the comment carries the text (incl. the '' escape)" "$(txtq "$WORK")" "the handbook, it's great"

blobhdr() { # <file>
    python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"the handbook, it's great")
print("NOT FOUND" if i < 0 else " ".join(str(b) for b in data[i-8:i]))
PY
}
check "the description blob record matches byte for byte" "$(blobhdr "$WORK")" "$(blobhdr "$REF")"
case "$(blobhdr "$WORK")" in
    *" 4 0 "*) echo "OK   the blob carries blh_charset = 4 (UTF8)" ;;
    *) echo "DIFF the description blob charset"; echo "     $(blobhdr "$WORK")"; fail=1 ;;
esac

# --- 2. clearing --------------------------------------------------------
check "COMMENT ON DATABASE IS NULL clears it" "$(node_run "$CLR")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$CLR;
COMMIT;
EOF
clearedq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END FROM RDB$DATABASE;
SQL
}
check "the description is NULL on both after the clear" "$(clearedq "$WORK")" "$(clearedq "$REF")"
check "fire-crab's database description is NULL after the clear" "$(clearedq "$WORK")" "null"

# --- 3. gbak and gfix ---------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cdb-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-cdb-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cdb-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cdb-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cdb-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
