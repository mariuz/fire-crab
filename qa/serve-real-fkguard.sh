#!/bin/bash
# The fc-side DML GUARD for FK-parent action triggers (system_flag 4).
#
# An FK referential action (CASCADE / SET NULL / SET DEFAULT) stores an
# AFTER UPDATE (type 4) / AFTER DELETE (type 6) system trigger on the
# REFERENCED (parent) table. The engine fires it; this server cannot
# execute trigger BLR - so its own DML path must refuse exactly the
# statements that would fire one, and allow the rest:
#   - INSERT into the parent never fires an action trigger - allowed;
#   - UPDATE of a NON-key parent column never acts (the trigger's OLD<>NEW
#     key guard is false) - allowed, and must match the engine's result;
#   - UPDATE touching a referenced KEY column would cascade - refused;
#   - DELETE of a parent row would cascade/SET NULL - refused;
#   - DML on a USER-trigger table (system_flag 0) is ALLOWED now: this
#     server fires the triggers it can run (serve-real-trigfire.sh), and
#     refuses only a body outside that surface.
# The guard reads the CATALOG (trigger rows + their RDB$DEPENDENCIES key
# columns), so it must hold on a database the ENGINE created.
#
# The differential is the engine, four ways:
#   1. the engine creates the same schema + rows on two copies; fire-crab
#      runs the DML matrix above against one, the engine mirrors only the
#      ALLOWED statements on the other; the tables match afterwards;
#   2. the refused statements changed nothing (same comparison);
#   3. after fire-crab's writes the engine still CASCADES on that file
#      (parent key update + delete through isql, contents match the ref);
#   4. gbak round trip and gfix -v -full on the file fire-crab wrote.
#
#   qa/serve-real-fkguard.sh [port]
#
# Builds its own scratch databases (both created by the engine).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4281}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fkg-work.fdb"; REF="$D/fc-fkg-ref.fdb"
FBK="$D/fc-fkg-work.fbk"; RST="$D/fc-fkg-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SCHEMA="CREATE TABLE MASTER (ID INTEGER NOT NULL PRIMARY KEY, VAL INTEGER);
CREATE TABLE DETAIL (CID INTEGER, MID INTEGER, CONSTRAINT FK_D FOREIGN KEY (MID) REFERENCES MASTER (ID) ON DELETE CASCADE ON UPDATE CASCADE);
CREATE TABLE P2 (A INTEGER NOT NULL PRIMARY KEY);
CREATE TABLE C2 (X INTEGER, CONSTRAINT FK_C2 FOREIGN KEY (X) REFERENCES P2 (A) ON DELETE SET NULL ON UPDATE SET NULL);
CREATE TABLE TD (ID INTEGER, B INTEGER);
COMMIT;
SET TERM ^;
CREATE TRIGGER TDAD FOR TD AFTER DELETE AS DECLARE VARIABLE V INTEGER; BEGIN V = OLD.ID; END^
SET TERM ;^
COMMIT;
INSERT INTO MASTER VALUES (1, 10);
INSERT INTO MASTER VALUES (2, 20);
INSERT INTO MASTER VALUES (3, 30);
INSERT INTO DETAIL VALUES (10, 1);
INSERT INTO DETAIL VALUES (11, 1);
INSERT INTO DETAIL VALUES (20, 2);
INSERT INTO P2 VALUES (1);
INSERT INTO C2 VALUES (1);
INSERT INTO TD VALUES (1, 2);
INSERT INTO TD VALUES (2, 3);
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SCHEMA
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fkg.log 2>&1 &
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
refuse() { # <label> <got>
    case "$2" in
        ERR*) echo "OK   $1" ;;
        *) echo "DIFF $1 (want refusal, got: $2)"; fail=1 ;;
    esac
}

# --- 1. the DML matrix through fire-crab -------------------------------
check  "parent INSERT is allowed (no action trigger fires on INSERT)" \
       "$(node_run 'INSERT INTO MASTER (ID, VAL) VALUES (4, 40)')" "OK"
check  "parent UPDATE of a NON-key column is allowed" \
       "$(node_run 'UPDATE MASTER SET VAL = 7 WHERE ID = 2')" "OK"
refuse "parent UPDATE touching the referenced KEY column refuses" \
       "$(node_run 'UPDATE MASTER SET ID = 99 WHERE ID = 1')"
refuse "parent DELETE refuses (AFTER DELETE cascade trigger)" \
       "$(node_run 'DELETE FROM MASTER WHERE ID = 3')"
check  "child DELETE is allowed (no trigger on the child)" \
       "$(node_run 'DELETE FROM DETAIL WHERE CID = 20')" "OK"
refuse "SET NULL parent key UPDATE refuses (guard is action-agnostic)" \
       "$(node_run 'UPDATE P2 SET A = 5 WHERE A = 1')"
refuse "SET NULL parent DELETE refuses" \
       "$(node_run 'DELETE FROM P2 WHERE A = 1')"
# a USER trigger no longer refuses the statement: this server FIRES the
# ones it can run (serve-real-trigfire.sh), and TD's AFTER DELETE body -
# a variable assignment over OLD - is one of them
check  "DELETE on a user-trigger table is allowed (the trigger fires)" \
       "$(node_run 'DELETE FROM TD WHERE ID = 1')" "OK"
check  "UPDATE on a user-trigger table is allowed (no UPDATE trigger there)" \
       "$(node_run 'UPDATE TD SET B = 9 WHERE ID = 2')" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. the engine mirrors the ALLOWED statements on the ref -----------
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO MASTER (ID, VAL) VALUES (4, 40);
UPDATE MASTER SET VAL = 7 WHERE ID = 2;
DELETE FROM DETAIL WHERE CID = 20;
DELETE FROM TD WHERE ID = 1;
UPDATE TD SET B = 9 WHERE ID = 2;
COMMIT;
SQL
dump() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'M|'||ID||'|'||COALESCE(VAL,-1) FROM MASTER ORDER BY ID;
SELECT 'D|'||CID||'|'||COALESCE(MID,-1) FROM DETAIL ORDER BY CID;
SELECT 'P|'||A FROM P2 ORDER BY A;
SELECT 'C|'||COALESCE(X,-1) FROM C2 ORDER BY 1;
SELECT 'T|'||ID||'|'||B FROM TD ORDER BY ID;
SQL
}
check "allowed writes match the engine; refused ones changed nothing" \
      "$(dump "$WORK")" "$(dump "$REF")"

# --- 3. the engine still CASCADES on the file fire-crab wrote ----------
for f in "$WORK" "$REF"; do
    "$ISQL" -q -b -user "$U" -pas "$P" "$f" >/dev/null 2>&1 <<'SQL'
UPDATE MASTER SET ID = 99 WHERE ID = 1;
DELETE FROM MASTER WHERE ID = 2;
COMMIT;
SQL
done
check "engine cascade on fc's file: key update moved children, delete removed one" \
      "$(dump "$WORK")" "$(dump "$REF")"
case "$(dump "$WORK")" in
    *"D|10|99"*"D|11|99"*)
        echo "OK   the cascade really ran (children follow the new key 99)" ;;
    *) echo "DIFF the cascade comparison was vacuous"; echo "     $(dump "$WORK")"; fail=1 ;;
esac

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fkg-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-fkg-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fkg-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-fkg-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-fkg-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
