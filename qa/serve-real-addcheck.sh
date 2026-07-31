#!/bin/bash
# ALTER TABLE ADD [CONSTRAINT <n>] CHECK - and DROP CONSTRAINT of one.
#
# ADD CHECK writes exactly the CREATE-time catalog (the CHECK_<n>
# trigger pair from the RDB$TRIGGER_NAME generator, verbatim source,
# negated-condition BLR, link + dependency rows, INTEG_<n> or the given
# name) plus a refresh of RDB$RUNTIME so the triggers load. The engine
# does NOT validate existing rows (probed: a violating row survives the
# ALTER untouched; only future DML is checked) - so neither does
# fire-crab. DROP CONSTRAINT tears it all down: the trigger pair, the
# dependency and link rows, the constraint row, and the runtime entries
# - after which the condition stops enforcing.
#
# The differential is the engine: identical base tables (with a
# violating row), the ALTERs done by fire-crab (work) vs the engine
# (ref); trigger/constraint/dependency rows incl. BLR hex, RDB$RUNTIME
# byte-for-byte after ADD and again after DROP, fire-crab's own DML
# enforcing the new check the moment it exists (NULL passes, 3VL), the
# ENGINE raising fc's triggers from the raw file (SQLSTATE 23000),
# identical contents, and gbak + gfix.
#
#   qa/serve-real-addcheck.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4258}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-addck-work.fdb"; REF="$D/fc-addck-ref.fdb"
FBK="$D/fc-addck-work.fbk"; RST="$D/fc-addck-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

BASE="CREATE TABLE AC1 (A INTEGER, B INTEGER);
COMMIT;
INSERT INTO AC1 VALUES (5, 1);
INSERT INTO AC1 VALUES (-3, 2);
COMMIT;"
S1="ALTER TABLE AC1 ADD CHECK (A > 0)"
S2="ALTER TABLE AC1 ADD CONSTRAINT CHK_B CHECK (B < 100)"
S3="ALTER TABLE AC1 DROP CONSTRAINT CHK_B"

for db in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $db"; exit 1; }
CREATE DATABASE '$db' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$BASE
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF || { echo "FAIL ref alters"; exit 1; }
$S1; COMMIT; $S2; COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-addck.log 2>&1 &
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

check "fire-crab: ADD CHECK over a table with a VIOLATING row" "$(node_run "$S1")" "OK"
check "fire-crab: ADD a NAMED check" "$(node_run "$S2")" "OK"
case "$(node_run 'ALTER TABLE AC1 ADD CHECK (NOPE > 0)')" in
    ERR*) echo "OK   a check on an unknown column refuses" ;;
    *) echo "DIFF unknown-column refusal"; fail=1 ;; esac
# the violating row is untouched - the engine's own rule
check "the pre-existing violating row survived the ADD" \
    "$(node_run 'SELECT A, B FROM AC1 ORDER BY A')" "-3|2 / 5|1"
# fire-crab's own DML enforces the check the moment it exists
check "fire-crab: a passing INSERT" "$(node_run 'INSERT INTO AC1 (A, B) VALUES (7, 3)')" "OK"
case "$(node_run 'INSERT INTO AC1 (A, B) VALUES (-1, 5)')" in
    ERR*) echo "OK   fire-crab REJECTS a violating INSERT through the added check" ;;
    *) echo "DIFF fc added-check insert"; fail=1 ;; esac
check "fire-crab: a NULL-operand check passes (3VL)" \
    "$(node_run 'INSERT INTO AC1 (B) VALUES (5)')" "OK"
case "$(node_run 'INSERT INTO AC1 (A, B) VALUES (1, 500)')" in
    ERR*) echo "OK   fire-crab rejects through the SECOND added check" ;;
    *) echo "DIFF fc second check"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the reference gets the same rows fire-crab's DML added
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO AC1 (A, B) VALUES (7, 3);
INSERT INTO AC1 (B) VALUES (5);
COMMIT;
SQL

catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$TRIGGER_INACTIVE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||t.RDB$VALID_BLR||'|'||CAST(t.RDB$TRIGGER_SOURCE AS VARCHAR(80))||'|'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(200) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$RELATION_NAME='AC1' ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(rc.RDB$CONSTRAINT_NAME)||'|'||TRIM(rc.RDB$CONSTRAINT_TYPE) FROM RDB$RELATION_CONSTRAINTS rc WHERE rc.RDB$RELATION_NAME='AC1' ORDER BY 1;
SELECT TRIM(cc.RDB$CONSTRAINT_NAME)||'->'||TRIM(cc.RDB$TRIGGER_NAME) FROM RDB$CHECK_CONSTRAINTS cc JOIN RDB$RELATION_CONSTRAINTS rc ON rc.RDB$CONSTRAINT_NAME=cc.RDB$CONSTRAINT_NAME WHERE rc.RDB$RELATION_NAME='AC1' ORDER BY 1;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$FIELD_NAME) FROM RDB$DEPENDENCIES d WHERE TRIM(d.RDB$DEPENDED_ON_NAME)='AC1' ORDER BY 1, 2;
SQL
}
work_c=$(catq "$WORK")
check "trigger/constraint/link/dependency rows match the engine after ADD" \
    "$work_c" "$(catq "$REF")"
case "$work_c" in *"0502083417010141"*) echo "OK   vacuous-guard: the added trigger BLR is the probed negated form" ;;
    *) echo "DIFF vacuous blr"; echo "     $work_c"; fail=1 ;; esac

rtq() { # <db> <tag>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT r.RDB$RUNTIME FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME='AC1';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f "/tmp/fc-addck-rt-$2.bin"
    printf 'BLOBDUMP %s /tmp/fc-addck-rt-%s.bin;\n' "$b" "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v "/tmp/fc-addck-rt-$2.bin" | tr '\n' ' ' | tr -s ' ' | strip; }
check "RDB\$RUNTIME matches byte for byte after ADD (four trigger names)" \
    "$(rtq "$WORK" w1)" "$(rtq "$REF" r1)"

# the ENGINE raises fc's added trigger from the raw file
viol() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -oE 'SQLSTATE = [0-9A-Za-z]+' | head -1
INSERT INTO AC1 (A, B) VALUES (-8, 1);
SQL
}
work_e=$(viol "$WORK")
check "the engine raises fc's added check identically" "$work_e" "$(viol "$REF")"
case "$work_e" in *23000*) echo "OK   vacuous-guard: the violation is SQLSTATE 23000" ;;
    *) echo "DIFF vacuous 23000"; fail=1 ;; esac

# DROP CONSTRAINT tears the named check down - fc on work, engine on ref
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >>/tmp/fc-serve-addck.log 2>&1 &
srv=$!
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
check "fire-crab: DROP CONSTRAINT of the named check" "$(node_run "$S3")" "OK"
check "fire-crab: a B >= 100 row now goes in (the check is GONE)" \
    "$(node_run 'INSERT INTO AC1 (A, B) VALUES (2, 500)')" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<SQL
$S3;
COMMIT;
INSERT INTO AC1 (A, B) VALUES (2, 500);
COMMIT;
SQL

work_c=$(catq "$WORK")
check "the catalog matches the engine after DROP (one pair left)" "$work_c" "$(catq "$REF")"
case "$work_c" in *CHK_B*) echo "DIFF vacuous drop"; echo "     $work_c"; fail=1 ;;
    *) echo "OK   vacuous-guard: no CHK_B trace remains" ;; esac
check "RDB\$RUNTIME matches byte for byte after DROP (two names left)" \
    "$(rtq "$WORK" w2)" "$(rtq "$REF" r2)"

valq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A, B FROM AC1 ORDER BY A, B;
SQL
}
check "final contents identical" "$(valq "$WORK")" "$(valq "$REF")"

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-addck-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab altered"
else echo "DIFF gbak backup"; cat /tmp/fc-addck-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-addck-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-addck-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-addck-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
