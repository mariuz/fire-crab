#!/bin/bash
# ALTER DOMAIN ... TYPE - retype a domain in place.
#
# A domain's type is its RDB$FIELDS row (RDB$FIELD_TYPE / LENGTH / SCALE /
# SUB_TYPE, and RDB$CHARACTER_LENGTH for text). ALTER DOMAIN TYPE rewrites those
# in place: INTEGER->BIGINT is type 8 len 4 -> type 16 len 8, VARCHAR(6)->(20)
# is len 6 -> len 20 with char length to match. Only a widening this write path
# performs (a wider integer, a same-or-longer CHAR/VARCHAR); a narrowing or an
# incompatible change errors, as the engine's does.
#
# fire-crab does not yet declare a table column with a user domain type, so the
# end-to-end proof runs the other way: fire-crab retypes DOM_I to BIGINT, and the
# ENGINE - creating a table that uses it, on fire-crab's own file - stores a value
# past the old INTEGER range in it.
#
# The differential is the engine (both databases start with the same domains,
# written by the engine; then fire-crab ALTERs one copy, the engine the other):
#   1. every domain's RDB$FIELDS type row is compared after the ALTERs
#      (type/length/char-length), for an integer and a VARCHAR widening;
#   2. a narrowing and an incompatible change are refused on both;
#   3. the engine stores a BIGINT-range value in fire-crab's retyped domain;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-alterdomaintype.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4194}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-adt-work.fdb"; REF="$D/fc-adt-ref.fdb"
FBK="$D/fc-adt-work.fbk"; RST="$D/fc-adt-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE DOMAIN DOM_I AS INTEGER; CREATE DOMAIN DOM_S AS SMALLINT; CREATE DOMAIN DOM_V AS VARCHAR(6); CREATE DOMAIN DOM_N AS VARCHAR(20);
CREATE DOMAIN DOM_FK AS INTEGER; CREATE DOMAIN DOM_PU AS INTEGER;
CREATE TABLE GM (Q INTEGER NOT NULL PRIMARY KEY, P DOM_PU);
CREATE TABLE GC (R DOM_FK REFERENCES GM (Q));"
I_BIG="ALTER DOMAIN DOM_I TYPE BIGINT"
S_INT="ALTER DOMAIN DOM_S TYPE INTEGER"
V_WIDE="ALTER DOMAIN DOM_V TYPE VARCHAR(20)"
NARROW="ALTER DOMAIN DOM_N TYPE VARCHAR(3)"
INCOMPAT="ALTER DOMAIN DOM_N TYPE INTEGER"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$I_BIG; $S_INT; $V_WIDE;
COMMIT;
ALTER DOMAIN DOM_PU TYPE BIGINT;
COMMIT;
EOF
eng_narrow=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$NARROW;
EOF
)
eng_incompat=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$INCOMPAT;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-adt.log 2>&1 &
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

check "fire-crab: INTEGER -> BIGINT"    "$(node_run "$I_BIG")"  "OK"
check "fire-crab: SMALLINT -> INTEGER"  "$(node_run "$S_INT")"  "OK"
check "fire-crab: VARCHAR(6) -> VARCHAR(20)" "$(node_run "$V_WIDE")" "OK"
r=$(node_run "$NARROW")
case "$r" in ERR*) echo "OK   a narrowing VARCHAR is refused" ;;
    *) echo "DIFF narrowing accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$INCOMPAT")
case "$r" in ERR*) echo "OK   an incompatible VARCHAR->INTEGER is refused" ;;
    *) echo "DIFF incompatible change accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_narrow$eng_incompat" in *[Ff]ailed*|*[Ee]rror*|*unsuccessful*) echo "OK   the engine refuses both too" ;;
    *) echo "DIFF engine did not refuse"; echo "     $eng_narrow / $eng_incompat"; fail=1 ;; esac
# the dependents guard (probed): a domain whose column sits in a
# FOREIGN KEY index refuses - "Cannot modify index used by an
# Integrity Constraint" - exactly as the engine does; any OTHER in-use
# domain refuses CONSERVATIVELY (the engine allows it, writing a new
# format version per dependent table - a slice fc does not write yet,
# so it refuses rather than leave catalog and formats disagreeing)
r=$(node_run "ALTER DOMAIN DOM_FK TYPE BIGINT")
case "$r" in ERR*) echo "OK   an FK-child domain is refused (engine parity)" ;;
    *) echo "DIFF FK-child domain guard"; echo "     $r"; fail=1 ;; esac
# an in-use (non-FK) domain retypes WITH a dependent format bump since
# inc 124 (deep differential: serve-real-domainretype)
r=$(node_run "ALTER DOMAIN DOM_PU TYPE BIGINT")
case "$r" in OK) echo "OK   an IN-USE domain retypes (dependent format bump, inc 124)" ;;
    *) echo "DIFF in-use domain retype"; echo "     $r"; fail=1 ;; esac

# --- 1. the retyped domain type rows -----------------------------------
infoq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|t='||RDB$FIELD_TYPE||'|len='||RDB$FIELD_LENGTH
       ||'|clen='||COALESCE(CAST(RDB$CHARACTER_LENGTH AS VARCHAR(4)),'-')
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME LIKE 'DOM\_%' ESCAPE '\' ORDER BY RDB$FIELD_NAME;
SQL
}
work_i=$(infoq "$WORK")
check "every domain's RDB\$FIELDS type row matches the engine after the ALTERs" "$work_i" "$(infoq "$REF")"
case "$work_i" in
    *"DOM_I|t=16|len=8"*"DOM_S|t=8|len=4"*"DOM_V|t=37|len=20|clen=20"*)
        echo "OK   INTEGER widened to BIGINT, SMALLINT to INTEGER, VARCHAR(6) to VARCHAR(20)" ;;
    *) echo "DIFF the type comparison was vacuous or wrong"; echo "     $work_i"; fail=1 ;;
esac

# --- 3. the engine stores a BIGINT-range value in fire-crab's domain ---
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
CREATE TABLE T (X DOM_I);
COMMIT;
INSERT INTO T VALUES (5000000000);
COMMIT;
SQL
big=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT CAST(X AS VARCHAR(20)) FROM T;
SQL
)
check "the engine stores a value past the old INTEGER range in the BIGINT domain" "$big" "5000000000"

# --- 4. gbak and gfix --------------------------------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the engine refuses the same FK-child domain retype on fc's file - the
# partner metadata fc preserves is what makes it refuse
engref=$("$ISQL" -q -user "$U" -pas "$P" "$WORK" 2>&1 <<< "ALTER DOMAIN DOM_FK TYPE BIGINT;")
case "$engref" in
    *"Integrity Constraint"*) echo "OK   the engine refuses the FK-child domain on fc's file" ;;
    *) echo "DIFF engine-side FK-domain refusal"; echo "     $engref"; fail=1 ;;
esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-adt-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-adt-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-adt-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-adt-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-adt-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
