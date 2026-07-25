#!/bin/bash
# User CREATE TRIGGER - PSQL to BLR.
#
# The compilable slice: `CREATE TRIGGER <n> FOR <t> [ACTIVE] BEFORE
# INSERT|UPDATE [POSITION <n>] AS BEGIN <statements> END`, statements
# being `NEW.<col> = <expr>;` and `IF (<cond>) THEN <stmt>` over the
# integer expression surface, references qualified NEW. (context 1) /
# OLD. (context 0). The BLR skeleton (probed byte-for-byte): version5,
# begin, label 0, begin, begin, statements, end x3 - an IF emits its
# condition AS WRITTEN (blr_gtr for >; the check-constraint negation is
# a DDL-time artifact, not a trigger one). The engine also stores an
# RDB$DEBUG_INFO blob - `01 02` then a `02 <line><col><blr-offset>`
# src-to-BLR entry for the BEGIN and each statement (1-based line and
# column in the ORIGINAL statement text), then FF - reproduced exactly.
# Catalog: system_flag 0, flags 1, POSITION -> RDB$TRIGGER_SEQUENCE,
# verbatim source from AS, per-field dependency rows, trigger name in
# RDB$RUNTIME.
#
# The differential is the engine, six ways:
#   1. fire-crab and the engine create three triggers; every catalog row
#      - BLR hex AND debug-info hex included - dependency rows and the
#      RDB$RUNTIME blob are compared byte for byte;
#   2. the ENGINE executes fire-crab's triggers from the raw file:
#      INSERT computes NEW.B, POSITION orders two BEFORE INSERT triggers
#      (the second overwrites for A > 10), UPDATE reads OLD.B;
#   3. fire-crab REFUSES what it cannot compile: AFTER events, DELETE,
#      unqualified references, NOT in the IF, unknown columns;
#   4. fire-crab REFUSES its own DML on a table with user triggers - it
#      does not execute trigger BLR, so writing anyway would silently
#      produce different data than the engine;
#   5. final contents identical;
#   6. gbak round trip and gfix -v -full.
#
#   qa/serve-real-trigger.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4261}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-trig-work.fdb"; REF="$D/fc-trig-ref.fdb"
FBK="$D/fc-trig-work.fbk"; RST="$D/fc-trig-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

T="CREATE TABLE T1 (A INTEGER, B INTEGER)"
TR1="CREATE TRIGGER TR1 FOR T1 BEFORE INSERT AS BEGIN NEW.B = NEW.A * 2; END"
TR2="CREATE TRIGGER TR2 FOR T1 BEFORE UPDATE POSITION 5 AS BEGIN NEW.B = OLD.B + 1; END"
TR3="CREATE TRIGGER TR3 FOR T1 BEFORE INSERT POSITION 1 AS BEGIN IF (NEW.A > 10) THEN NEW.B = 0; END"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$T;
COMMIT;
SET TERM ^ ;
$TR1^
$TR2^
$TR3^
SET TERM ; ^
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-trig.log 2>&1 &
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
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }

check "fire-crab: the table" "$(node_run "$T")" "OK"
check "fire-crab: BEFORE INSERT trigger (NEW.B = NEW.A * 2)" "$(node_run "$TR1")" "OK"
check "fire-crab: BEFORE UPDATE trigger reading OLD, POSITION 5" "$(node_run "$TR2")" "OK"
check "fire-crab: IF (cond) THEN body, POSITION 1" "$(node_run "$TR3")" "OK"
case "$(node_run 'CREATE TRIGGER TX FOR T1 AFTER INSERT AS BEGIN NEW.B = 1; END')" in
    ERR*) echo "OK   AFTER triggers refuse (outside the slice)" ;;
    *) echo "DIFF after refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE DELETE AS BEGIN NEW.B = 1; END')" in
    ERR*) echo "OK   DELETE triggers refuse (no NEW row there)" ;;
    *) echo "DIFF delete refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE INSERT AS BEGIN B = 1; END')" in
    ERR*) echo "OK   an unqualified reference refuses" ;;
    *) echo "DIFF unqualified refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE INSERT AS BEGIN IF (NOT (NEW.A > 1)) THEN NEW.B = 0; END')" in
    ERR*) echo "OK   NOT in the IF refuses (the engine would emit blr_not)" ;;
    *) echo "DIFF not refusal"; fail=1 ;; esac
case "$(node_run 'CREATE TRIGGER TX FOR T1 BEFORE INSERT AS BEGIN NEW.NOPE = 1; END')" in
    ERR*) echo "OK   an unknown target column refuses" ;;
    *) echo "DIFF unknown-col refusal"; fail=1 ;; esac
# fire-crab does not execute trigger BLR - its own DML on this table
# must REFUSE rather than silently skip the triggers
case "$(node_run 'INSERT INTO T1 (A) VALUES (1)')" in
    ERR*) echo "OK   fire-crab REFUSES its own DML on a user-trigger table" ;;
    *) echo "DIFF fc dml refusal"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$TRIGGER_INACTIVE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||t.RDB$VALID_BLR||'|'||CAST(t.RDB$TRIGGER_SOURCE AS VARCHAR(120))
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME='T1' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'#'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS)||'#'||CAST(CAST(t.RDB$DEBUG_INFO AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME='T1' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$DEPENDED_ON_NAME)||'|'||TRIM(d.RDB$FIELD_NAME)||'|'||d.RDB$DEPENDENT_TYPE||'|'||d.RDB$DEPENDED_ON_TYPE
FROM RDB$DEPENDENCIES d WHERE d.RDB$DEPENDENT_NAME STARTING WITH 'TR' ORDER BY 1;
SQL
}
work_c=$(catq "$WORK")
check "every trigger row (BLR + debug-info hex) and dependency matches the engine" \
    "$work_c" "$(catq "$REF")"
# vacuous: TR1's BLR is the probed skeleton and the debug map is present
case "$work_c" in *"0502110002020124170101411508000200000017010142FFFFFF4C"*)
    echo "OK   vacuous-guard: TR1's BLR is the probed label-begin skeleton" ;;
    *) echo "DIFF vacuous blr"; echo "     $work_c"; fail=1 ;; esac
case "$work_c" in *"010202010000002C"*)
    echo "OK   vacuous-guard: the debug-info source map is byte-exact" ;;
    *) echo "DIFF vacuous dbg"; fail=1 ;; esac

rtq() { # <db> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB$RUNTIME FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME='T1';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-trig-rt-$2.bin"
    printf 'BLOBDUMP %s /tmp/fc-trig-rt-%s.bin;\n' "$b" "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-trig-rt-$2.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "RDB\$RUNTIME matches byte for byte (three trigger names)" \
    "$(rtq "$WORK" w)" "$(rtq "$REF" r)"

# the ENGINE executes fire-crab's triggers from the raw file
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO T1 (A) VALUES (4);
INSERT INTO T1 (A) VALUES (20);
COMMIT;
UPDATE T1 SET A = 5 WHERE A = 4;
COMMIT;
SQL
}
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*|*SQLSTATE*) echo "DIFF engine DML through fc's triggers"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine fires fire-crab's triggers" ;; esac

valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A, B FROM T1 ORDER BY A;
SQL
}
work_v=$(valq "$WORK")
check "the trigger-computed values are identical" "$work_v" "$(valq "$REF")"
# A=5: TR1 made B=8 on insert of 4, TR2 made B=9 on update (OLD.B + 1);
# A=20: TR1 made B=40, then TR3 (POSITION 1, later) overwrote with 0
case "$work_v" in *"5            9"*|*"5 9"*)
    case "$work_v" in *"20            0"*|*"20 0"*)
        echo "OK   vacuous-guard: OLD.B arithmetic and POSITION ordering both showed" ;;
        *) echo "DIFF vacuous position"; echo "     $work_v"; fail=1 ;; esac ;;
    *) echo "DIFF vacuous old"; echo "     $work_v"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-trig-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-trig-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-trig-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-trig-restore.log; then echo "OK   gbak RESTORES it (the trigger catalog survives)"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-trig-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
