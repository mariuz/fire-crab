#!/bin/bash
# TRIGGER SURFACE GROWTH, round three: NOT folding, WHILE, EXCEPTION,
# INSERT-INTO-another-table (blr_store), WHEN ANY DO handlers, and
# MULTI-EVENT triggers. (UPDATE OF does not exist in Firebird - probed
# syntax error - the old to-do note was mistaken.)
#
# ENGINE FACTS (probed byte for byte):
#   - NOT never emits blr_not for comparisons: the DSQL pass FOLDS it
#     (NOT(A>1) -> blr_leq; De Morgan through AND/OR); the ONE blr_not
#     is NOT(x IS NULL) -> blr_not(blr_missing);
#   - WHILE (c) DO s -> blr_label n, blr_loop, begin, blr_if(c, s,
#     blr_leave n), end - TWO debug entries at the WHILE, label + if;
#   - EXCEPTION name -> blr_abort, condition 2, name; one dependency
#     row with DEPENDED_ON_TYPE 7;
#   - INSERT INTO t (cols) VALUES (exprs) -> blr_store over
#     blr_relation with its own context (2, 3, ...); dependencies: the
#     relation row plus one per stored column;
#   - WHEN ANY DO s (last in block) -> blr_handler wraps the protected
#     begin, blr_error_handler + count 1 + condition 4 (ANY);
#   - multi-event RDB$TRIGGER_TYPE encodes the WRITTEN order: first
#     event's single code + ordinal(e2)*8 + ordinal(e3)*32 (BEFORE
#     INSERT OR UPDATE 17, BEFORE UPDATE OR INSERT 11, the triple 113).
#
# The differential: fire-crab and the engine create the same triggers
# on two copies - rows, BLR, DEBUG_INFO and dependencies byte for byte;
# the engine EXECUTES every fire-crab trigger (loop counts, the raised
# exception, the logged store rows, the handler catching a divide by
# zero, both events of a multi-event trigger); refusals; gbak + gfix.
#
#   qa/serve-real-trigger3.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4290}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-trg3-work.fdb"; REF="$D/fc-trg3-ref.fdb"
FBK="$D/fc-trg3-work.fbk"; RST="$D/fc-trg3-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DDL=(
  "CREATE TABLE TN (A INTEGER, B INTEGER)"
  "CREATE TABLE TW (A INTEGER, B INTEGER)"
  "CREATE TABLE TE (A INTEGER, B INTEGER)"
  "CREATE TABLE TS (A INTEGER, B INTEGER)"
  "CREATE TABLE TH (A INTEGER, B INTEGER)"
  "CREATE TABLE TM (A INTEGER, B INTEGER)"
  "CREATE TABLE LOG (X INTEGER, Y INTEGER)"
  "CREATE EXCEPTION EX1 'boom'"
  "CREATE TRIGGER TRNOT FOR TN BEFORE INSERT AS BEGIN IF (NOT (NEW.A > 1 AND NEW.A < 5)) THEN NEW.B = 0; ELSE NEW.B = 9; END"
  "CREATE TRIGGER TRISN FOR TN BEFORE INSERT POSITION 1 AS BEGIN IF (NOT (NEW.B IS NULL)) THEN NEW.B = NEW.B + 1; END"
  "CREATE TRIGGER TRWHILE FOR TW BEFORE INSERT AS DECLARE VARIABLE V INTEGER; BEGIN V = 0; WHILE (V < NEW.A) DO V = V + 1; NEW.B = V * 2; END"
  "CREATE TRIGGER TREXC FOR TE BEFORE INSERT AS BEGIN IF (NEW.A = 9) THEN EXCEPTION EX1; END"
  "CREATE TRIGGER TRSTORE FOR TS AFTER INSERT AS BEGIN INSERT INTO LOG (X, Y) VALUES (NEW.A + 1, NEW.B * 2); END"
  "CREATE TRIGGER TRHAND FOR TH BEFORE INSERT AS BEGIN NEW.B = 100 / NEW.A; WHEN ANY DO NEW.B = -1; END"
  "CREATE TRIGGER TRMULTI FOR TM BEFORE INSERT OR UPDATE AS BEGIN NEW.B = NEW.A * 10; END"
  "CREATE TRIGGER TRORD FOR TM BEFORE UPDATE OR INSERT POSITION 3 AS BEGIN NEW.B = NEW.B + 1; END"
  "CREATE TRIGGER TRUD FOR TM AFTER UPDATE OR DELETE AS DECLARE VARIABLE V INTEGER; BEGIN V = OLD.A; INSERT INTO LOG (X, Y) VALUES (:V, 0 - 1); END"
)

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
done
# the engine runs the identical DDL on the ref (triggers via SET TERM)
{
    for s in "${DDL[@]}"; do
        case "$s" in
            "CREATE TRIGGER"*) printf 'SET TERM ^;\n%s^\nSET TERM ;^\nCOMMIT;\n' "$s" ;;
            *) printf '%s;\nCOMMIT;\n' "$s" ;;
        esac
    done
} | "$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-trg3.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_q() {
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
        r=$(node_q "$1")
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

# --- 1. fire-crab compiles every shape ----------------------------------
for s in "${DDL[@]}"; do
    check "fire-crab: ${s:15:44}..." "$(node_run "$s")" "OK"
done
# refusals: WHEN not last, unknown exception, store arity, WHILE sans DO
for bad in \
  "CREATE TRIGGER BX FOR TN BEFORE INSERT AS BEGIN WHEN ANY DO NEW.B = 1; NEW.B = 2; END" \
  "CREATE TRIGGER BX FOR TN BEFORE INSERT AS BEGIN EXCEPTION NOSUCH; END" \
  "CREATE TRIGGER BX FOR TS AFTER INSERT AS BEGIN INSERT INTO LOG (X, Y) VALUES (1); END" \
  "CREATE TRIGGER BX FOR TW BEFORE INSERT AS BEGIN WHILE (NEW.A > 0) NEW.A = 1; END" \
  "CREATE TRIGGER BX FOR TM AFTER DELETE AS DECLARE VARIABLE V INTEGER; BEGIN V = OLD.A; INSERT INTO LOG (X, Y) VALUES (V, 1); END"; do
    case "$(node_run "$bad")" in
        ERR*) echo "OK   refuses: ${bad:36:44}..." ;;
        *) echo "DIFF refusal: $bad"; fail=1 ;;
    esac
done
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. rows, BLR, DEBUG_INFO and dependencies byte for byte ------------
catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||CAST(t.RDB$TRIGGER_SOURCE AS VARCHAR(200))
FROM RDB$TRIGGERS t WHERE t.RDB$TRIGGER_NAME STARTING WITH 'TR' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'#'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(400) CHARACTER SET OCTETS)||'@'||CAST(CAST(t.RDB$DEBUG_INFO AS BLOB SUB_TYPE 0) AS VARCHAR(500) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$TRIGGER_NAME STARTING WITH 'TR' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$DEPENDED_ON_NAME)||'|'||COALESCE(TRIM(d.RDB$FIELD_NAME),'-')||'|'||d.RDB$DEPENDED_ON_TYPE
FROM RDB$DEPENDENCIES d WHERE d.RDB$DEPENDENT_NAME STARTING WITH 'TR'
ORDER BY d.RDB$DEPENDENT_NAME, d.RDB$DEPENDED_ON_NAME, COALESCE(TRIM(d.RDB$FIELD_NAME),'-');
SQL
}
work_c=$(catq "$WORK")
check "every trigger row, BLR+DEBUG blob and dependency matches the engine" "$work_c" "$(catq "$REF")"
case "$work_c" in
    *"TRMULTI|17|"*"TRORD|11|3"*"TRUD|28|"*"TREXC|EX1|-|7"*"TRSTORE|LOG|-|0"*"TRSTORE|LOG|X|0"*)
        echo "OK   the teeth bite: types 17/11/28, the type-7 exception dep, the store's relation+field deps" ;;
    *) echo "DIFF the catalog comparison was vacuous"; echo "     $work_c" | head -c 600; fail=1 ;;
esac
rtq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | wc -l
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME IN ('TN','TM');
SQL
}
blobq() { # <file> <rel>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB\$RUNTIME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = '$2';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-trg3-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-trg3-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-trg3-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
for t in TN TM TS; do
    check "$t RDB\$RUNTIME (trigger names in firing order) matches byte for byte" \
          "$(blobq "$WORK" "$t")" "$(blobq "$REF" "$t")"
done

# --- 3. the engine EXECUTES fire-crab's triggers ------------------------
exec_dml() { # <file>
    "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
INSERT INTO TN (A) VALUES (3);
INSERT INTO TN (A) VALUES (0);
INSERT INTO TW (A) VALUES (4);
INSERT INTO TE (A) VALUES (1);
INSERT INTO TE (A) VALUES (9);
INSERT INTO TS (A, B) VALUES (5, 6);
INSERT INTO TH (A) VALUES (4);
INSERT INTO TH (A) VALUES (0);
INSERT INTO TM (A) VALUES (3);
COMMIT;
UPDATE TM SET A = 5 WHERE A = 30 OR B = 31;
UPDATE TM SET A = 5;
DELETE FROM TM;
COMMIT;
SET HEADING OFF;
SELECT 'TN|'||A||'|'||B FROM TN ORDER BY A;
SELECT 'TW|'||A||'|'||B FROM TW;
SELECT 'TE|'||A FROM TE;
SELECT 'TH|'||A||'|'||B FROM TH ORDER BY A;
SELECT 'LOG|'||X||'|'||Y FROM LOG ORDER BY X, Y;
SQL
}
work_x=$(exec_dml "$WORK")
check "the engine RUNS them: fold/ELSE, loop, exception, store, handler, multi-event" \
      "$work_x" "$(exec_dml "$REF")"
case "$work_x" in
    *"boom"*"TN|0|1"*"TN|3|10"*"TW|4|8"*"TH|0|-1"*"TH|4|25"*"LOG|5|-1"*"LOG|6|12"*)
        echo "OK   observable: EX1 raised, fold+ELSE+chain 9->10, loop 4->8, handler caught /0, store+multi-delete logged" ;;
    *) echo "DIFF the execution comparison was vacuous"; echo "     $work_x" | head -c 400; fail=1 ;;
esac

# --- 4. gbak and gfix ----------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-trg3-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-trg3-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-trg3-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-trg3-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-trg3-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
