#!/bin/bash
# The NO-ACTION FOREIGN KEY partner check - the half of referential
# integrity the engine enforces with partner INDEX lookups, not triggers
# (idx.epp via MET_lookup_partner), so the flag-4 trigger guard never
# sees it. fire-crab now runs the same checks itself, per row, at
# execute:
#   - child-side: a stored row's non-NULL FK key must exist in the
#     referenced table (MATCH SIMPLE - any NULL component passes);
#   - parent-side: a deleted row's key, or a key an UPDATE changes away
#     from, must not be referenced by any child row; an untouched or
#     unreferenced key never blocks.
#
# The differential is the engine, four ways:
#   1. the engine creates the same schema + rows on two copies;
#      fire-crab runs a 16-statement DML matrix against one, the engine
#      runs the IDENTICAL matrix on the other; every allow/refuse
#      verdict matches statement by statement;
#   2. the final table contents match - so everything fire-crab allowed
#      the engine allowed, and everything it refused the engine refused;
#   3. the engine still enforces the FK on the file fire-crab wrote;
#   4. gbak round trip and gfix -v -full.
#
#   qa/serve-real-fkpartner.sh [port]
#
# Builds its own scratch databases (both created by the engine).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4282}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fkp-work.fdb"; REF="$D/fc-fkp-ref.fdb"
FBK="$D/fc-fkp-work.fbk"; RST="$D/fc-fkp-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SCHEMA="CREATE TABLE MASTER (ID INTEGER NOT NULL PRIMARY KEY, VAL INTEGER);
CREATE TABLE DETAIL (CID INTEGER, MID INTEGER, CONSTRAINT FK_D FOREIGN KEY (MID) REFERENCES MASTER (ID));
CREATE TABLE P2 (A INTEGER NOT NULL, B INTEGER NOT NULL, PRIMARY KEY (A, B));
CREATE TABLE C2 (X INTEGER, Y INTEGER, CONSTRAINT FK_C2 FOREIGN KEY (X, Y) REFERENCES P2 (A, B));
COMMIT;
INSERT INTO MASTER VALUES (1, 10);
INSERT INTO MASTER VALUES (2, 20);
INSERT INTO MASTER VALUES (3, 30);
INSERT INTO MASTER VALUES (4, 40);
INSERT INTO DETAIL VALUES (10, 1);
INSERT INTO DETAIL VALUES (11, 1);
INSERT INTO P2 VALUES (7, 8);
INSERT INTO C2 VALUES (7, 8);
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SCHEMA
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fkp.log 2>&1 &
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

# --- 1. the DML matrix: fire-crab and the engine, verdict by verdict ---
# each entry: <want OK|ERR> <statement>. The engine runs the same list
# on the ref copy afterwards; the wanted verdicts are the ENGINE's.
MATRIX=(
  "OK  INSERT INTO DETAIL VALUES (20, 2)"
  "ERR INSERT INTO DETAIL VALUES (30, 777)"
  "OK  INSERT INTO DETAIL VALUES (40, NULL)"
  "OK  UPDATE DETAIL SET MID = 3 WHERE CID = 11"
  "ERR UPDATE DETAIL SET MID = 888 WHERE CID = 10"
  "ERR DELETE FROM MASTER WHERE ID = 1"
  "ERR UPDATE MASTER SET ID = 55 WHERE ID = 1"
  "OK  UPDATE MASTER SET ID = 55 WHERE ID = 4"
  "OK  INSERT INTO DETAIL VALUES (60, 55)"
  "OK  UPDATE MASTER SET VAL = 9 WHERE ID = 1"
  "ERR DELETE FROM MASTER WHERE ID = 2"
  "OK  DELETE FROM DETAIL WHERE CID = 20"
  "OK  DELETE FROM MASTER WHERE ID = 2"
  "OK  INSERT INTO C2 VALUES (7, NULL)"
  "ERR INSERT INTO C2 VALUES (8, 8)"
  "ERR DELETE FROM P2 WHERE A = 7"
)
for entry in "${MATRIX[@]}"; do
    want=${entry%% *}; stmt=$(printf '%s' "${entry#* }" | strip)
    got=$(node_run "$stmt")
    case "$want:$got" in
        OK:OK) echo "OK   fc allows:  $stmt" ;;
        ERR:ERR*) echo "OK   fc refuses: $stmt" ;;
        *) echo "DIFF fc verdict for: $stmt"; echo "     want $want, got: $got"; fail=1 ;;
    esac
done
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. the engine runs the IDENTICAL matrix on the ref copy -----------
{
    for entry in "${MATRIX[@]}"; do
        printf '%s;\nCOMMIT;\n' "$(printf '%s' "${entry#* }" | strip)"
    done
} | "$ISQL" -q -user "$U" -pas "$P" "$REF" >/tmp/fc-fkp-mirror.log 2>&1
# (no -b: the 7 expected FK violations must not bail the mirror script)
mirror_errs=$(grep -c "SQLSTATE = 23000" /tmp/fc-fkp-mirror.log)
check "the engine refused the same 7 statements (SQLSTATE 23000 each)" "$mirror_errs" "7"

dump() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'M|'||ID||'|'||COALESCE(VAL,-1) FROM MASTER ORDER BY ID;
SELECT 'D|'||CID||'|'||COALESCE(MID,-1) FROM DETAIL ORDER BY CID;
SELECT 'P|'||A||'|'||B FROM P2 ORDER BY A;
SELECT 'C|'||COALESCE(X,-1)||'|'||COALESCE(Y,-1) FROM C2 ORDER BY 1;
SQL
}
work_d=$(dump "$WORK")
check "final contents match the engine, table by table" "$work_d" "$(dump "$REF")"
case "$work_d" in
    *"M|1|9"*"M|55|40"*"D|60|55"*)
        echo "OK   the allowed writes really landed (VAL=9, key 4->55, child of 55)" ;;
    *) echo "DIFF the content comparison was vacuous"; echo "     $work_d"; fail=1 ;;
esac

# --- 3. the engine still enforces the FK on fire-crab's file -----------
enf=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO DETAIL VALUES (70, 777);
SQL
)
case "$enf" in
    *"SQLSTATE = 23000"*"FK_D"*) echo "OK   the engine refuses an orphan on fc's file (FK_D intact)" ;;
    *) echo "DIFF engine enforcement on fc's file"; echo "     $enf"; fail=1 ;;
esac

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fkp-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-fkp-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fkp-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-fkp-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-fkp-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
