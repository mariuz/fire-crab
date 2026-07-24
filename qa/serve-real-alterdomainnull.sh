#!/bin/bash
# ALTER DOMAIN SET / DROP NOT NULL - a domain's nullability, changed in place.
#
# A domain's nullability is RDB$NULL_FLAG on its RDB$FIELDS row. SET NOT NULL
# writes 1; DROP NOT NULL writes 0 (probe: a dropped constraint leaves the flag
# at 0, distinct from a domain that never had one, whose flag is NULL). A column
# that uses the domain inherits the constraint, and the engine enforces (or
# stops enforcing) it on the next insert.
#
# fire-crab does not yet declare a table column with a user domain type, so the
# end-to-end proof runs the other way: fire-crab changes the domain, and the
# ENGINE - creating a table that uses it, on fire-crab's own file - refuses a
# NULL into a column of the now-NOT NULL domain, and accepts one into a column
# of the domain whose constraint was dropped.
#
# The differential is the engine (both databases start with the same domains,
# written by the engine; then fire-crab ALTERs one copy, the engine the other):
#   1. every RDB$NULL_FLAG is compared after the ALTERs (SET->1, DROP->0, and a
#      never-touched domain stays NULL);
#   2. the engine ENFORCES fire-crab's SET NOT NULL: a NULL insert into a column
#      of the domain is refused;
#   3. the engine ACCEPTS a NULL into a column of the DROP NOT NULL domain;
#   4. an unknown domain is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-alterdomainnull.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4192}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-adn-work.fdb"; REF="$D/fc-adn-ref.fdb"
FBK="$D/fc-adn-work.fbk"; RST="$D/fc-adn-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE DOMAIN DOM_PLAIN AS INTEGER; CREATE DOMAIN DOM_SET AS INTEGER; CREATE DOMAIN DOM_DROP AS INTEGER NOT NULL;"
A_SET="ALTER DOMAIN DOM_SET SET NOT NULL"
A_DROP="ALTER DOMAIN DOM_DROP DROP NOT NULL"
R_UNK="ALTER DOMAIN NOSUCH SET NOT NULL"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$A_SET; $A_DROP;
COMMIT;
EOF
eng_unk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_UNK;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-adn.log 2>&1 &
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

check "fire-crab: SET NOT NULL"  "$(node_run "$A_SET")"  "OK"
check "fire-crab: DROP NOT NULL" "$(node_run "$A_DROP")" "OK"
r=$(node_run "$R_UNK")
case "$r" in ERR*) echo "OK   an unknown domain is refused" ;;
    *) echo "DIFF unknown domain accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_unk" in *[Ee]rror*|*"not found"*|*"not defined"*) echo "OK   the engine refuses the unknown domain too" ;;
    *) echo "DIFF engine did not refuse unknown domain"; echo "     $eng_unk"; fail=1 ;; esac

# --- 1. the null flags after the ALTERs --------------------------------
flagsq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$NULL_FLAG AS VARCHAR(4)),'NULL')
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME LIKE 'DOM\_%' ESCAPE '\' ORDER BY RDB$FIELD_NAME;
SQL
}
work_f=$(flagsq "$WORK")
check "every domain's RDB\$NULL_FLAG matches the engine after the ALTERs" "$work_f" "$(flagsq "$REF")"
case "$work_f" in
    *"DOM_DROP|0"*"DOM_PLAIN|NULL"*"DOM_SET|1"*)
        echo "OK   SET->1, DROP->0, a never-touched domain stays NULL" ;;
    *) echo "DIFF the flag comparison was vacuous or wrong"; echo "     $work_f"; fail=1 ;;
esac

# --- 2/3. the engine enforces / stops enforcing on fire-crab's file ----
enf=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
CREATE TABLE T (X DOM_SET);
COMMIT;
INSERT INTO T VALUES (NULL);
SQL
)
case "$enf" in *[Vv]alidation*|*"*** null ***"*) echo "OK   the engine enforces fire-crab's SET NOT NULL (NULL refused)" ;;
    *) echo "DIFF the engine did not enforce the domain NOT NULL"; echo "     $enf"; fail=1 ;; esac

allow=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
CREATE TABLE V (Z DOM_DROP);
COMMIT;
INSERT INTO V VALUES (NULL);
COMMIT;
SET HEADING OFF;
SELECT 'rows='||COUNT(*) FROM V;
SQL
)
case "$allow" in *"rows=1"*) echo "OK   the engine accepts a NULL into the DROP NOT NULL domain" ;;
    *) echo "DIFF the engine rejected a NULL the DROP should have allowed"; echo "     $allow"; fail=1 ;; esac

# --- 5. gbak and gfix --------------------------------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-adn-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-adn-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-adn-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-adn-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-adn-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
