#!/bin/bash
# A DML STATEMENT WHOSE TARGET NAMES NO RELATION is the engine's -204 at
# prepare - `Dynamic SQL Error / SQL error code = -204 / Table unknown /
# "S2" / At line L, column C` - where this server answered a bare
# Dynamic SQL Error. Measured on 6.0.0.2196 over the wire (node sends the
# text verbatim, so the positions are the text's own):
#
#   INSERT          at the INSERT keyword itself (`   INSERT ..` column 4;
#                   two newlines down, line 3) - DEFAULT VALUES and a
#                   SELECT source the same
#   UPDATE / DELETE / MERGE   at the target's name, a delimited one at its
#                   opening quote (`DELETE\n FROM "s2"` line 2 column 7)
#   UPDATE OR INSERT          line 0, column 0
#
# Every script that runs DDL under a savepoint meets it: 6.0.0.2196 refuses
# the CREATE TABLE (serve-real-ddlsavepoint.sh) and the INSERT that follows
# names a table that was never made.  A PUBLIC-qualified target prints
# `"PUBLIC"."S2"` (section 2).
#
#   qa/serve-real-dmlunknown.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4591}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dmlunk-eng.fdb"; FC="$D/dmlunk-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE KEEP (ID INTEGER, A INTEGER);
CREATE GLOBAL TEMPORARY TABLE GT (X INTEGER);
CREATE VIEW VW AS SELECT ID FROM KEEP;
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/dmlunk-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/dmlunk-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-dmlunk-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
q() { FC_Q="$1" FC_PORT="$2" FC_DB="$3" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,[],(e2)=>{
        const d=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):"ok";
        tr.rollback(()=>{console.log(d);db.detach();process.exit(0);});
      });
    });
  });' 2>/dev/null; }
both() { # <label> <sql>
    ran=$((ran + 1))
    local ev fv
    ev=$(q "$2" "$REAL" "$ENG"); fv=$(q "$2" "$PORT" "$FC")
    if [ -z "$ev" ] || [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}

echo "--- 1 the target names no relation: -204 at prepare, placed per verb"
both "1 INSERT - at the INSERT keyword"         "INSERT INTO S2 VALUES (1)"
both "1 INSERT after three blanks - column 4"   "   INSERT INTO S2 VALUES (1)"
both "1 INSERT two lines down, lower case"      $'\n\n  insert into s2 values (1)'
both "1 INSERT .. DEFAULT VALUES"               "INSERT INTO S2 DEFAULT VALUES"
both "1 INSERT .. SELECT - the target first"    "INSERT INTO S2 (A) SELECT ID FROM KEEP"
both "1 UPDATE - at the name"                   "UPDATE   S2 SET A = 1"
both "1 UPDATE with an alias"                   "UPDATE S2 X SET A = 1"
both "1 DELETE - a delimited name at its quote" $'DELETE\n FROM "s2"'
both "1 MERGE - at the name"                    "MERGE INTO S2 USING KEEP ON 1 = 1 WHEN MATCHED THEN DELETE"
both "1 UPDATE OR INSERT - line 0, column 0"    "UPDATE OR INSERT INTO S2 VALUES (1) MATCHING (A)"

echo "--- 2 a PUBLIC-qualified target: printed qualified, placed at the qualifier"
# (recorded as a bare refusal until 2026-10-03; UPDATE OR INSERT's qualified
# form is placed at the DOT where its unqualified one is line 0, column 0)
both "2 INSERT INTO PUBLIC.S2"                  "INSERT INTO PUBLIC.S2 VALUES (1)"
both "2 UPDATE PUBLIC.S2 - at PUBLIC"           "UPDATE PUBLIC.S2 SET A = 1"
both "2 DELETE FROM \"PUBLIC\".S2"             'DELETE FROM "PUBLIC".S2'
both "2 MERGE INTO PUBLIC.S2"                   "MERGE INTO PUBLIC.S2 USING KEEP ON 1 = 1 WHEN MATCHED THEN DELETE"
both "2 UPDATE OR INSERT INTO PUBLIC.S2 - at the dot" "UPDATE OR INSERT INTO PUBLIC.S2 VALUES (1) MATCHING (A)"
both "2 UPDATE PUBLIC . S2 - spaced"            "UPDATE PUBLIC . S2 SET A = 1"

echo "--- 3 CONTROLS - a target that exists is untouched"
both "3 INSERT into a GTT"                      "INSERT INTO GT VALUES (1)"
both "3 UPDATE a view"                          "UPDATE VW SET ID = 1 WHERE 1 = 0"
both "3 DELETE from a table"                    "DELETE FROM KEEP WHERE 1 = 0"
both "3 INSERT into a table"                    "INSERT INTO KEEP VALUES (1, 2)"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-dmlunk-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 21 on the 2026-10-03 binary, 21 OK
if [ "$ran" -lt 21 ]; then echo "FAIL only $ran checks ran (floor 21) - cells went missing"; fail=1; fi
exit $fail
