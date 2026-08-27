#!/bin/bash
# Trigger surface growth: AFTER events, DELETE triggers, DECLARE
# VARIABLE, and IF..ELSE.
#
# All probed byte-for-byte: RDB$TRIGGER_TYPE covers all six events
# (BI 1, AI 2, BU 3, AU 4, BD 5, AD 6); a DECLARE VARIABLE body emits
# ALL blr_dcl_variable declares first (SMALLINT blr_short, INTEGER
# blr_long, BIGINT blr_int64), then a NULL-init assignment per variable
# - each init being its DECLARE statement's debug-map entry - before the
# label; variables read and assign as blr_variable slots; an ELSE branch
# simply replaces blr_if's missing-else end marker and gets its own
# debug entry; the debug blob lists fb_dbg_map_varname items (slot,
# name) ahead of the source map. Variables are what make AFTER and
# DELETE trigger bodies expressible at all in the integer surface -
# NEW is only assignable in BEFORE INSERT/UPDATE, INSERT triggers have
# no OLD row, DELETE triggers no NEW.
#
# The differential is the engine: eight triggers (all six events,
# multi-variable and multiline sources included) built by fire-crab vs
# the engine; every catalog row with BLR hex AND debug-info hex, the
# dependency rows and RDB$RUNTIME byte for byte; the ENGINE executing
# the whole BEFORE INSERT chain from fc's raw file (variables carrying
# values across statements, both ELSE arms, POSITION ordering) and
# firing the AFTER/DELETE triggers; five compile refusals; fc's own DML
# refusal; identical contents; gbak + gfix.
#
#   qa/serve-real-trigger2.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4278}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-trig2-work.fdb"; REF="$D/fc-trig2-ref.fdb"
FBK="$D/fc-trig2-work.fbk"; RST="$D/fc-trig2-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

T="CREATE TABLE T1 (A INTEGER, B INTEGER)"
TA="CREATE TRIGGER TA FOR T1 AFTER INSERT AS DECLARE VARIABLE V INTEGER; BEGIN V = NEW.A; END"
TB="CREATE TRIGGER TB FOR T1 BEFORE DELETE AS DECLARE VARIABLE V INTEGER; BEGIN V = OLD.A; END"
TC="CREATE TRIGGER TC FOR T1 BEFORE INSERT AS DECLARE VARIABLE V INTEGER; BEGIN V = NEW.A * 2; NEW.B = V + 1; END"
TD="CREATE TRIGGER TD FOR T1 BEFORE INSERT POSITION 2 AS BEGIN IF (NEW.A > 10) THEN NEW.B = 1; ELSE NEW.B = 2; END"
TE="CREATE TRIGGER TE FOR T1 AFTER UPDATE AS DECLARE VARIABLE V INTEGER; BEGIN V = OLD.B; END"
TF="CREATE TRIGGER TF FOR T1 AFTER DELETE AS DECLARE VARIABLE V INTEGER; BEGIN V = OLD.A; END"
TG="CREATE TRIGGER TG FOR T1 BEFORE INSERT POSITION 3 AS
DECLARE VARIABLE V INTEGER;
DECLARE VARIABLE W BIGINT;
BEGIN V = 5; W = NEW.A; NEW.B = NEW.B + V; END"
TH="CREATE TRIGGER TH FOR T1 BEFORE INSERT POSITION 4 AS DECLARE VARIABLE S SMALLINT; BEGIN S = 3; END"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$T;
COMMIT;
SET TERM ^ ;
$TA^
$TB^
$TC^
$TD^
$TE^
$TF^
$TG^
$TH^
SET TERM ; ^
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-trig2.log 2>&1 &
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

check "fire-crab: the table" "$(node_run "$T")" "OK"
check "fire-crab: AFTER INSERT with DECLARE (type 2)" "$(node_run "$TA")" "OK"
check "fire-crab: BEFORE DELETE reading OLD (type 5)" "$(node_run "$TB")" "OK"
check "fire-crab: variable carries a value across statements" "$(node_run "$TC")" "OK"
check "fire-crab: IF .. THEN .. ELSE" "$(node_run "$TD")" "OK"
check "fire-crab: AFTER UPDATE (type 4)" "$(node_run "$TE")" "OK"
check "fire-crab: AFTER DELETE (type 6)" "$(node_run "$TF")" "OK"
check "fire-crab: two variables (INTEGER + BIGINT), multiline source" "$(node_run "$TG")" "OK"
check "fire-crab: a SMALLINT variable" "$(node_run "$TH")" "OK"
case "$(node_run 'CREATE TRIGGER TX FOR T1 AFTER INSERT AS BEGIN NEW.B = 1; END')" in
    ERR*) echo "OK   assigning NEW in an AFTER trigger refuses" ;;
    *) echo "DIFF after-assign refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE DELETE AS DECLARE VARIABLE V INTEGER; BEGIN V = NEW.A; END')" in
    ERR*) echo "OK   reading NEW in a DELETE trigger refuses" ;;
    *) echo "DIFF delete-new refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE INSERT AS BEGIN V = 1; END')" in
    ERR*) echo "OK   an undeclared variable target refuses" ;;
    *) echo "DIFF undeclared refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE INSERT AS DECLARE VARIABLE V VARCHAR(5); BEGIN NEW.B = 1; END')" in
    ERR*) echo "OK   a non-integer variable type refuses" ;;
    *) echo "DIFF vartype refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE INSERT AS BEGIN ELSE NEW.B = 1; END')" in
    ERR*) echo "OK   ELSE without an IF refuses" ;;
    *) echo "DIFF else refusal"; fail=1 ;; esac
# fire-crab FIRES its own triggers now (serve-real-trigfire.sh); the
# ENGINE makes the same insert into the reference file, so the value
# comparison below still compares like with like
case "$(node_run 'INSERT INTO T1 (A) VALUES (1)')" in
    ERR*) echo "DIFF fc dml on a user-trigger table refused"; fail=1 ;;
    *) echo "OK   fire-crab fires its own triggers on its own DML" ;; esac
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO T1 (A) VALUES (1);
COMMIT;
SQL
kill $srv 2>/dev/null; wait $srv 2>/dev/null

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$TRIGGER_INACTIVE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||t.RDB$VALID_BLR
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME='T1' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'#'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS)||'#'||CAST(CAST(t.RDB$DEBUG_INFO AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME='T1' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$FIELD_NAME) FROM RDB$DEPENDENCIES d WHERE d.RDB$DEPENDENT_NAME STARTING WITH 'T' ORDER BY 1, 2;
SQL
}
work_c=$(catq "$WORK")
check "every trigger row (BLR + debug hex) and dependency matches the engine" \
    "$work_c" "$(catq "$REF")"
# vacuous: TG's two-variable declare block and the varname map are present
case "$work_c" in *"050203000008000301001000012D1A0000012D1A0100"*)
    echo "OK   vacuous-guard: TG's declare-then-init block is the probed byte form" ;;
    *) echo "DIFF vacuous declares"; echo "     $work_c"; fail=1 ;; esac
case "$work_c" in *"01020300000156030100015702"*)
    echo "OK   vacuous-guard: the two-variable name map leads TG's debug blob" ;;
    *) echo "DIFF vacuous varmap"; fail=1 ;; esac

rtq() { # <db> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB$RUNTIME FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME='T1';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-trig2-rt-$2.bin"
    printf 'BLOBDUMP %s /tmp/fc-trig2-rt-%s.bin;\n' "$b" "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-trig2-rt-$2.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "RDB\$RUNTIME matches byte for byte (eight names, sequence-then-name order)" \
    "$(rtq "$WORK" w)" "$(rtq "$REF" r)"

# the ENGINE executes the whole trigger chain from fc's raw file
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO T1 (A) VALUES (4);
INSERT INTO T1 (A) VALUES (20);
INSERT INTO T1 (A) VALUES (30);
COMMIT;
UPDATE T1 SET A = 5 WHERE A = 4;
DELETE FROM T1 WHERE A = 30;
COMMIT;
SQL
}
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*|*SQLSTATE*) echo "DIFF engine DML through fc's triggers"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine fires all six trigger events from fc's file" ;; esac

valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A, B FROM T1 ORDER BY A;
SQL
}
work_v=$(valq "$WORK")
check "the trigger-computed values are identical" "$work_v" "$(valq "$REF")"
# A=5 (was 4): TC B=9, TD else B=2, TG B=2+5=7 - the ELSE arm + variable
# chain; A=20: TD then B=1, TG B=1+5=6 - the THEN arm; the deleted row
# went through both DELETE triggers
case "$work_v" in *"5            7"*|*"5 7"*)
    case "$work_v" in *"20            6"*|*"20 6"*)
        echo "OK   vacuous-guard: both ELSE arms and the variable chain showed" ;;
        *) echo "DIFF vacuous then"; echo "     $work_v"; fail=1 ;; esac ;;
    *) echo "DIFF vacuous else"; echo "     $work_v"; fail=1 ;; esac
case "$work_v" in *"30"*) echo "DIFF vacuous delete"; echo "     $work_v"; fail=1 ;;
    *) echo "OK   vacuous-guard: the row passed through the DELETE triggers and is gone" ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-trig2-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-trig2-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-trig2-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-trig2-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-trig2-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
