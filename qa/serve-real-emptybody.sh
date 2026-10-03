#!/bin/bash
# AN EMPTY PSQL BODY - `AS BEGIN END` - compiles, stores the engine's BLR
# byte for byte, and runs.
#
# CREATE PROCEDURE / FUNCTION with an empty body refused at prepare (the
# compiler rejected an empty statement list), and an empty TRIGGER body was
# accepted but stored `begin begin end end` where the engine stores
# `begin end`. Measured on 6.0.0.2196: AN EMPTY BLOCK IS ITS WRAPPER ALONE -
# the body `label 0, begin, end`, a nested `BEGIN END` and an IF's empty
# branch `begin end`, an empty WHEN-handler body `begin end` with no
# blr_block - while a block with statements keeps its statement list.
# EXECUTE PROCEDURE answers its outputs NULL, a selectable call without a
# SUSPEND is the engine's "not selectable", a function without a RETURN
# answers NULL.
#
# ...and a TRIGGER BODY WITH EXIT (section 4) stores too: EXIT is `blr_leave
# 0` - the body's own label, from inside an IF or a WHILE alike - with its
# debug entry at the leave. It refused at prepare as "interpreter-only".
#
# Each statement runs against the ENGINE on one file and fire-crab on its
# twin; the stored BLR is then read back from both through the engine's
# own server (node, the blob as hex) and compared.
#
#   qa/serve-real-emptybody.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4593}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/emptybody-eng.fdb"; FC="$D/emptybody-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INTEGER);
CREATE TABLE T2 (ID INTEGER);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/emptybody-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/emptybody-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-emptybody-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# one isql script on each server, the whole output compared
both() {
    ran=$((ran + 1))
    local e c
    e=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
# a catalog BLR blob as hex, read through the ENGINE's server from a file
blr() { FC_DB="$1" FC_Q="$2" timeout 25 node -e '
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_REAL,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,d)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    d.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,[],async(e2,rows)=>{
        if(e2||!rows||!rows.length){console.log("NONE");process.exit(0);}
        const v=Object.values(rows[0])[0];
        if(typeof v!=="function"){console.log("NULL");process.exit(0);}
        v(tr,(e3,n,em)=>{const b=[];em.on("data",c=>b.push(c));em.on("end",()=>{console.log(Buffer.concat(b).toString("hex"));tr.rollback(()=>process.exit(0));});});
      });
    });
  });' 2>/dev/null; }
same_blr() { # <label> <sql reading one blob>
    ran=$((ran + 1))
    local e c
    e=$(FC_REAL=$REAL blr "$ENG" "$2"); c=$(FC_REAL=$REAL blr "$FC" "$2")
    if [ -z "$e" ] || [ "$e" = NONE ] || [ "$e" = CONN_ERR ]; then echo "FAIL $1 [the engine's object is missing: $e]"; fail=1
    elif [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
R="RDB\$"

echo "--- 1 the empty bodies compile on both servers"
both "1 procedures, a function, nested and declared" \
"CREATE PROCEDURE P1 AS BEGIN END^
CREATE PROCEDURE P2 (X INTEGER) RETURNS (Y INTEGER) AS BEGIN END^
CREATE FUNCTION F1 RETURNS INTEGER AS BEGIN END^
CREATE PROCEDURE P6 AS BEGIN BEGIN END END^
CREATE PROCEDURE P7 (X INTEGER) RETURNS (Y INTEGER) AS DECLARE V INTEGER; BEGIN END^"
both "1 triggers: empty, declared, nested, an empty IF branch, an empty handler" \
"CREATE TRIGGER TR1 FOR T BEFORE INSERT AS BEGIN END^
CREATE TRIGGER TR4 FOR T BEFORE INSERT AS DECLARE V INTEGER; BEGIN END^
CREATE TRIGGER TR5 FOR T BEFORE INSERT AS BEGIN BEGIN END NEW.ID = 1; END^
CREATE TRIGGER TR6 FOR T BEFORE INSERT AS BEGIN IF (NEW.ID = 1) THEN BEGIN END ELSE NEW.ID = 2; END^
CREATE TRIGGER TR7 FOR T BEFORE INSERT AS BEGIN BEGIN END WHEN ANY DO BEGIN END END^"

echo "--- 2 the stored BLR is the engine's, byte for byte"
for n in P1 P2 P6 P7; do
    same_blr "2 procedure $n" "SELECT ${R}PROCEDURE_BLR FROM ${R}PROCEDURES WHERE ${R}PROCEDURE_NAME = '$n'"
done
same_blr "2 function F1" "SELECT ${R}FUNCTION_BLR FROM ${R}FUNCTIONS WHERE ${R}FUNCTION_NAME = 'F1'"
for n in TR1 TR4 TR5 TR6 TR7; do
    same_blr "2 trigger $n" "SELECT ${R}TRIGGER_BLR FROM ${R}TRIGGERS WHERE ${R}TRIGGER_NAME = '$n'"
done

echo "--- 3 they run"
both "3 EXECUTE PROCEDURE answers its outputs NULL" "EXECUTE PROCEDURE P1^
EXECUTE PROCEDURE P2(1)^
EXECUTE PROCEDURE P7(3)^"
both "3 a selectable call with no SUSPEND is not selectable" "SELECT * FROM P2(1)^"
both "3 a function with no RETURN answers NULL" "SELECT F1() FROM ${R}DATABASE^"
both "3 the triggers fire" "INSERT INTO T VALUES (5)^
SELECT ID FROM T^"

echo "--- 4 EXIT in a trigger body: blr_leave 0, and it leaves"
both "4 EXIT alone, under an IF, inside a WHILE" \
"CREATE TRIGGER TX1 FOR T2 BEFORE INSERT POSITION 1 AS BEGIN EXIT; END^
CREATE TRIGGER TX2 FOR T2 BEFORE INSERT POSITION 2 AS BEGIN IF (NEW.ID = 1) THEN EXIT; NEW.ID = NEW.ID * 10; END^
CREATE TRIGGER TX3 FOR T2 BEFORE INSERT POSITION 3 AS DECLARE I INTEGER; BEGIN I = 0; WHILE (I < 3) DO BEGIN I = I + 1; IF (I = 2) THEN EXIT; END NEW.ID = 0; END^"
for n in TX1 TX2 TX3; do
    same_blr "4 trigger $n BLR" "SELECT ${R}TRIGGER_BLR FROM ${R}TRIGGERS WHERE ${R}TRIGGER_NAME = '$n'"
    same_blr "4 trigger $n debug info" "SELECT ${R}DEBUG_INFO FROM ${R}TRIGGERS WHERE ${R}TRIGGER_NAME = '$n'"
done
both "4 the EXITs leave: 1 stays 1, 2 is 20, never 0" "INSERT INTO T2 VALUES (1)^
INSERT INTO T2 VALUES (2)^
SELECT ID FROM T2 ORDER BY ID^"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-emptybody-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 25 on the 2026-10-03 binary, 25 OK
if [ "$ran" -lt 25 ]; then echo "FAIL only $ran checks ran (floor 25) - cells went missing"; fail=1; fi
exit $fail
