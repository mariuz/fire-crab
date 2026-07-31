#!/bin/bash
# CHECK constraints - the expression compiler's boolean layer.
#
# A CHECK is a PAIR of CHECK_<n> triggers (before-insert type 1,
# before-update type 3, numbered from the RDB$TRIGGER_NAME generator)
# carrying the SAME BLR: `if <NEGATED condition> then abort
# check_constraint` - the negation De-Morgan-pushed to INVERTED
# comparison opcodes (probed: `CHECK (A = 1 OR NOT (A >= 10))` stores
# `blr_and(blr_neq, blr_geq)`, no blr_not), fields in context 1, which
# is also what keeps SQL's rule that an UNKNOWN (NULL-operand) check
# PASSES. Catalog: verbatim RDB$TRIGGER_SOURCE, system_flag 3, an
# INTEG_<n>/named RDB$RELATION_CONSTRAINTS 'CHECK' row numbered in
# DECLARATION order (interleaving NOT NULL and PRIMARY KEY), two
# RDB$CHECK_CONSTRAINTS rows, per-field RDB$DEPENDENCIES rows, and the
# trigger names in RDB$RUNTIME (a trigger absent there never fires).
#
# The differential is the engine, six ways:
#   1. fire-crab and the engine create the same four CHECK tables; every
#      trigger row (type/flags/source/BLR hex), constraint row, link row
#      and dependency row is compared;
#   2. RDB$RUNTIME is compared BYTE FOR BYTE (CK1, and CK5 - NOT NULL +
#      CHECK + PRIMARY KEY + CHECK interleaved);
#   3. fire-crab ENFORCES its checks on its own DML: violating INSERT
#      and UPDATE error, a NULL-operand check passes (3VL), and a check
#      it cannot evaluate (column-vs-column) REFUSES DML outright;
#   4. the ENGINE executes fire-crab's triggers from the raw file: a
#      violating insert raises SQLSTATE 23000 exactly like the
#      reference - including the column-vs-column check fc itself
#      refused to evaluate;
#   5. final table contents identical;
#   6. gbak round trip and gfix -v -full.
#
#   qa/serve-real-check.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4251}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-check-work.fdb"; REF="$D/fc-check-ref.fdb"
FBK="$D/fc-check-work.fbk"; RST="$D/fc-check-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

T1="CREATE TABLE CK1 (A INTEGER, B INTEGER, CHECK (A > 0))"
T2="CREATE TABLE CK2 (A INTEGER, B INTEGER, CONSTRAINT CHK_AB CHECK (A < B))"
T3="CREATE TABLE CK3 (A INTEGER, CHECK (A <> 0 AND A <= 100))"
T5="CREATE TABLE CK5 (A INTEGER NOT NULL, B INTEGER, CHECK (B > 0), PRIMARY KEY (A), CHECK (B < 100))"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$T1; $T2; $T3; $T5;
COMMIT;
INSERT INTO CK1 (A, B) VALUES (5, 1);
INSERT INTO CK1 (B) VALUES (7);
UPDATE CK1 SET A = 9 WHERE B = 1;
INSERT INTO CK3 (A) VALUES (50);
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-check.log 2>&1 &
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
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          console.log(r.map(row=>Object.values(row).map(v=>v===null?"NULL":String(v)).join("|")).join(" / "));
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

check "fire-crab: a plain CHECK" "$(node_run "$T1")" "OK"
check "fire-crab: a NAMED column-vs-column CHECK" "$(node_run "$T2")" "OK"
check "fire-crab: AND of two comparisons" "$(node_run "$T3")" "OK"
check "fire-crab: NOT NULL + CHECK + PRIMARY KEY + CHECK interleaved" "$(node_run "$T5")" "OK"

# fire-crab enforces its own checks on its own DML
check "fire-crab: a passing INSERT" "$(node_run 'INSERT INTO CK1 (A, B) VALUES (5, 1)')" "OK"
case "$(node_run 'INSERT INTO CK1 (A, B) VALUES (-1, 1)')" in
    ERR*) echo "OK   fire-crab REJECTS a violating INSERT" ;;
    *) echo "DIFF fc insert enforcement"; fail=1 ;; esac
check "fire-crab: a NULL-operand check PASSES (three-valued logic)" \
    "$(node_run 'INSERT INTO CK1 (B) VALUES (7)')" "OK"
case "$(node_run 'UPDATE CK1 SET A = -5 WHERE B = 1')" in
    ERR*) echo "OK   fire-crab REJECTS a violating UPDATE" ;;
    *) echo "DIFF fc update enforcement"; fail=1 ;; esac
check "fire-crab: a passing UPDATE" "$(node_run 'UPDATE CK1 SET A = 9 WHERE B = 1')" "OK"
check "fire-crab: AND check passes in range" "$(node_run 'INSERT INTO CK3 (A) VALUES (50)')" "OK"
case "$(node_run 'INSERT INTO CK3 (A) VALUES (101)')" in
    ERR*) echo "OK   fire-crab rejects the AND check's upper bound" ;;
    *) echo "DIFF fc AND high"; fail=1 ;; esac
case "$(node_run 'INSERT INTO CK3 (A) VALUES (0)')" in
    ERR*) echo "OK   fire-crab rejects the AND check's other arm" ;;
    *) echo "DIFF fc AND zero"; fail=1 ;; esac
# column-vs-column checks: once outside fc's evaluation surface (DML
# refused), ENFORCED since the fallible-predicate slice made A < B an
# evaluable term - a passing insert goes through, a violating one
# rejects, exactly like the engine
check "fire-crab enforces the column-vs-column check (pass)" \
    "$(node_run 'INSERT INTO CK2 (A, B) VALUES (1, 2)')" "OK"
case "$(node_run 'INSERT INTO CK2 (A, B) VALUES (9, 2)')" in
    ERR*) echo "OK   fire-crab rejects the column-vs-column violation" ;;
    *) echo "DIFF fc col-vs-col violation"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the ENGINE executes fire-crab's triggers from the raw file
viol() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
$2;
SQL
}
work_e=$(viol "$WORK" 'INSERT INTO CK1 (A, B) VALUES (-3, 4)')
check "the engine RAISES fc's check trigger on a violating insert" \
    "$work_e" "$(viol "$REF" 'INSERT INTO CK1 (A, B) VALUES (-3, 4)')"
case "$work_e" in *23000*) echo "OK   vacuous-guard: the violation is SQLSTATE 23000" ;;
    *) echo "DIFF vacuous 23000"; echo "     $work_e"; fail=1 ;; esac
check "the engine raises the column-vs-column check fc also enforces" \
    "$(viol "$WORK" 'INSERT INTO CK2 (A, B) VALUES (5, 2)')" \
    "$(viol "$REF" 'INSERT INTO CK2 (A, B) VALUES (5, 2)')"
# mirror fc's accepted CK2 row on the reference (fc already wrote it
# into the working file above), then the shared CK5 insert on both
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO CK2 (A, B) VALUES (1, 2);
COMMIT;
SQL
ins() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL'
INSERT INTO CK5 (A, B) VALUES (1, 50);
COMMIT;
SQL
}
ins "$REF" >/dev/null 2>&1
insw=$(ins "$WORK")
case "$insw" in *[Ee]rror*|*SQLSTATE*) echo "DIFF engine passing inserts"; echo "     $insw"; fail=1 ;;
    *) echo "OK   the engine's passing inserts go through fc's triggers" ;; esac

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||TRIM(t.RDB$RELATION_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$TRIGGER_INACTIVE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||t.RDB$VALID_BLR||'|'||CAST(t.RDB$TRIGGER_SOURCE AS VARCHAR(80))||'|'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(200) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME IN ('CK1','CK2','CK3','CK5') ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(rc.RDB$RELATION_NAME)||'|'||TRIM(rc.RDB$CONSTRAINT_NAME)||'|'||TRIM(rc.RDB$CONSTRAINT_TYPE) FROM RDB$RELATION_CONSTRAINTS rc WHERE rc.RDB$RELATION_NAME IN ('CK1','CK2','CK3','CK5') ORDER BY 1;
SELECT TRIM(cc.RDB$CONSTRAINT_NAME)||'->'||TRIM(cc.RDB$TRIGGER_NAME) FROM RDB$CHECK_CONSTRAINTS cc JOIN RDB$RELATION_CONSTRAINTS rc ON rc.RDB$CONSTRAINT_NAME=cc.RDB$CONSTRAINT_NAME WHERE rc.RDB$RELATION_NAME IN ('CK1','CK2','CK3','CK5') ORDER BY 1;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$DEPENDED_ON_NAME)||'|'||TRIM(d.RDB$FIELD_NAME)||'|'||d.RDB$DEPENDENT_TYPE||'|'||d.RDB$DEPENDED_ON_TYPE FROM RDB$DEPENDENCIES d WHERE d.RDB$DEPENDENT_NAME STARTING WITH 'CHECK_' ORDER BY 1, 3;
SQL
}
work_c=$(catq "$WORK")
check "every trigger/constraint/link/dependency row matches the engine" "$work_c" "$(catq "$REF")"
# vacuous: the BLR hex holds the negated condition - CHECK (A > 0)
# stores blr_leq(52=0x34) over field ctx 1 'A' vs literal 0
case "$work_c" in *"0502083417010141"*) echo "OK   vacuous-guard: CK1's trigger BLR is the probed negated form" ;;
    *) echo "DIFF vacuous blr"; echo "     $work_c"; fail=1 ;; esac

rtq() { # <db> <table> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB\$RUNTIME FROM RDB\$RELATIONS r WHERE r.RDB\$RELATION_NAME='$2';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-check-rt-$3.bin"
    printf 'BLOBDUMP %s /tmp/fc-check-rt-%s.bin;\n' "$b" "$3" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-check-rt-$3.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "CK1's RDB\$RUNTIME matches byte for byte (trigger names present)" \
    "$(rtq "$WORK" CK1 w1)" "$(rtq "$REF" CK1 r1)"
check "CK5's RDB\$RUNTIME matches byte for byte (checks + key + not null)" \
    "$(rtq "$WORK" CK5 w5)" "$(rtq "$REF" CK5 r5)"

valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'CK1', A, B FROM CK1 ORDER BY B;
SELECT 'CK2', A, B FROM CK2 ORDER BY A;
SELECT 'CK3', A FROM CK3 ORDER BY A;
SELECT 'CK5', A, B FROM CK5 ORDER BY A;
SQL
}
work_v=$(valq "$WORK")
check "final table contents identical" "$work_v" "$(valq "$REF")"
case "$work_v" in *"<null>"*) echo "OK   vacuous-guard: the NULL-operand row survived on both" ;;
    *) echo "DIFF vacuous null"; echo "     $work_v"; fail=1 ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-check-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-check-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-check-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-check-restore.log; then echo "OK   gbak RESTORES it (the CHECK catalog survives the round trip)"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-check-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
