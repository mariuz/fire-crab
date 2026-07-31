#!/bin/bash
# FOREIGN KEY ON DELETE / ON UPDATE SET DEFAULT.
#
# Unlike CASCADE and SET NULL, a SET DEFAULT trigger does NOT bake the
# default in: per child column it declares a PAIR of variables typed as
# the column itself (blr_column_name; flag 1 carries the column's
# DEFAULT), then `var := NULL; block { init_variable evaluates the
# CURRENT default; copy } handler(any){}` - so the default is fetched at
# RUNTIME (an ALTER ... SET DEFAULT changes what the trigger assigns,
# with no trigger rewrite), a column with no default gets NULL, and the
# assigned value must itself satisfy the FK or the statement fails.
# The rest is the SET NULL skeleton assigning the variables, wrapped in
# an outer begin..end (probed byte-for-byte, single and multi column).
#
# The differential is the engine, six ways:
#   1. fire-crab and the engine build the same four FK tables; every
#      parent-side trigger row (BLR hex included) and RDB$REF_CONSTRAINTS
#      rule is compared, and both parents' RDB$RUNTIME byte-for-byte;
#   2. the ENGINE fires fire-crab's triggers from the raw file: a parent
#      delete sets the child to its default;
#   3. fire-crab then ALTERs the child's DEFAULT, and the engine's next
#      parent delete assigns the NEW default - the runtime fetch, with
#      fc's inc-79 default write feeding fc's own trigger;
#   4. a column with NO default gets NULL on parent update; a default
#      with no matching parent row fails SQLSTATE 23000 identically;
#      multi-column keys assign both defaults;
#   5. final contents identical;
#   6. gbak round trip and gfix -v -full.
#
#   qa/serve-real-fkdefault.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4254}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fkdef-work.fdb"; REF="$D/fc-fkdef-ref.fdb"
FBK="$D/fc-fkdef-work.fbk"; RST="$D/fc-fkdef-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

T1="CREATE TABLE P (ID INTEGER PRIMARY KEY)"
T2="CREATE TABLE C1 (X INTEGER DEFAULT 42, FOREIGN KEY (X) REFERENCES P (ID) ON DELETE SET DEFAULT)"
T3="CREATE TABLE C2 (X INTEGER, FOREIGN KEY (X) REFERENCES P (ID) ON UPDATE SET DEFAULT)"
T4="CREATE TABLE P2 (A INTEGER, B INTEGER, PRIMARY KEY (A, B))"
T5="CREATE TABLE C3 (X INTEGER DEFAULT 1, Y INTEGER DEFAULT 2, FOREIGN KEY (X, Y) REFERENCES P2 (A, B) ON DELETE SET DEFAULT ON UPDATE SET DEFAULT)"
ALT="ALTER TABLE C1 ALTER COLUMN X SET DEFAULT 7"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$T1; $T2; $T3; $T4; $T5;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fkdef.log 2>&1 &
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
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }

check "fire-crab: parent with PRIMARY KEY" "$(node_run "$T1")" "OK"
check "fire-crab: ON DELETE SET DEFAULT (child default 42)" "$(node_run "$T2")" "OK"
check "fire-crab: ON UPDATE SET DEFAULT (no default)" "$(node_run "$T3")" "OK"
check "fire-crab: two-column parent key" "$(node_run "$T4")" "OK"
check "fire-crab: multi-column SET DEFAULT, both actions" "$(node_run "$T5")" "OK"
# the engine refuses a default change on an FK column ("cannot modify
# index used by an integrity constraint", probed) - fire-crab must too
case "$(node_run "$ALT")" in
    ERR*) echo "OK   fire-crab refuses SET DEFAULT on an FK column, like the engine" ;;
    *) echo "DIFF fk-column default refusal"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null
# ... and the refusal is the engine's own on both files
altq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
$ALT;
SQL
}
check "the engine refuses the same ALTER on both files" "$(altq "$WORK")" "$(altq "$REF")"

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||TRIM(t.RDB$RELATION_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||t.RDB$VALID_BLR||'|'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(400) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME IN ('P','P2') ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(rf.RDB$CONSTRAINT_NAME)||'|'||TRIM(rf.RDB$UPDATE_RULE)||'|'||TRIM(rf.RDB$DELETE_RULE)||'|'||TRIM(rf.RDB$MATCH_OPTION) FROM RDB$REF_CONSTRAINTS rf ORDER BY 1;
SQL
}
work_c=$(catq "$WORK")
check "every SET DEFAULT trigger and REF_CONSTRAINTS rule matches the engine" \
    "$work_c" "$(catq "$REF")"
# vacuous: the runtime-default preamble - declare var0 typed
# blr_column_name(21) flag 0 on C1.X = 03 00 00 15 00 02 'C1' 01 'X'
case "$work_c" in *"0300001500024331015803010015010243310158"*)
    echo "OK   vacuous-guard: the variable-pair preamble is the probed byte form" ;;
    *) echo "DIFF vacuous preamble"; echo "     $work_c"; fail=1 ;; esac
case "$work_c" in *"|SET DEFAULT|RESTRICT|"*) echo "OK   vacuous-guard: an ON UPDATE SET DEFAULT rule row is present" ;;
    *) echo "DIFF vacuous rule"; fail=1 ;; esac

rtq() { # <db> <table> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB\$RUNTIME FROM RDB\$RELATIONS r WHERE r.RDB\$RELATION_NAME='$2';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-fkdef-rt-$3.bin"
    printf 'BLOBDUMP %s /tmp/fc-fkdef-rt-%s.bin;\n' "$b" "$3" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-fkdef-rt-$3.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "parent P's RDB\$RUNTIME matches byte for byte (triggers named)" \
    "$(rtq "$WORK" P wp)" "$(rtq "$REF" P rp)"
check "parent P2's RDB\$RUNTIME matches byte for byte" \
    "$(rtq "$WORK" P2 wp2)" "$(rtq "$REF" P2 rp2)"

# the ENGINE fires fire-crab's triggers - identical steps on both files
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO P (ID) VALUES (1);
INSERT INTO P (ID) VALUES (42);
INSERT INTO P (ID) VALUES (100);
INSERT INTO C1 (X) VALUES (1);
INSERT INTO C2 (X) VALUES (100);
INSERT INTO P2 (A, B) VALUES (1, 2);
INSERT INTO P2 (A, B) VALUES (5, 6);
INSERT INTO C3 (X, Y) VALUES (5, 6);
COMMIT;
DELETE FROM P WHERE ID = 1;
UPDATE P SET ID = 101 WHERE ID = 100;
DELETE FROM P2 WHERE A = 5 AND B = 6;
COMMIT;
SQL
}
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*|*SQLSTATE*) echo "DIFF engine DML through fc's triggers"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine fires fire-crab's SET DEFAULT triggers" ;; esac

valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'C1', X FROM C1;
SELECT 'C2', X FROM C2;
SELECT 'C3', X, Y FROM C3;
SQL
}
work_v=$(valq "$WORK")
check "the defaults landed identically" "$work_v" "$(valq "$REF")"
# C1: the delete assigned the declared default 42
case "$work_v" in *"C1                 42"*|*"C1 42"*)
    echo "OK   vacuous-guard: the parent delete assigned the child's default 42" ;;
    *) echo "DIFF vacuous default42"; echo "     $work_v"; fail=1 ;; esac
# C2 had no default: the update set NULL
case "$work_v" in *"<null>"*) echo "OK   vacuous-guard: the no-default column went NULL" ;;
    *) echo "DIFF vacuous nulldefault"; fail=1 ;; esac
# C3: both columns took their defaults (1, 2)
case "$work_v" in *"C3                  1            2"*|*"C3 1 2"*)
    echo "OK   vacuous-guard: the multi-column defaults (1, 2) both landed" ;;
    *) echo "DIFF vacuous multi"; echo "     $work_v"; fail=1 ;; esac

# a SET DEFAULT whose value has no parent row fails - the child now
# points at 42; deleting parent 42 would re-assign 42, which is going
# away with this very delete
viol() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
DELETE FROM P WHERE ID = 42;
SQL
}
work_x=$(viol "$WORK")
check "a default with no matching parent row fails identically" "$work_x" "$(viol "$REF")"
case "$work_x" in *23000*) echo "OK   vacuous-guard: the failure is SQLSTATE 23000" ;;
    *) echo "DIFF vacuous 23000"; echo "     $work_x"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fkdef-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-fkdef-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fkdef-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-fkdef-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-fkdef-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
