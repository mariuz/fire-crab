#!/bin/bash
# THE SESSION'S OWN FACTS. `CURRENT_CONNECTION` in a statement was refused
# outright (it worked only as a column DEFAULT), the session-bound SYSTEM
# context keys answered NULL, and MON$ATTACHMENTS left the client's own
# words NULL - its process id and name, host, OS user, library version -
# along with the cipher's name and the compression flag.
#
# Measured on 6.0.0.2196:
#   CURRENT_CONNECTION       BIGINT NOT NULL, named CURRENT_CONNECTION;
#                            = SESSION_ID = this row's MON$ATTACHMENT_ID
#   DB_NAME                  = MON$DATABASE_NAME
#   CLIENT_ADDRESS           = MON$REMOTE_ADDRESS (`127.0.0.1/<port>`)
#   CLIENT_PID / _PROCESS    the dpb's isc_dpb_process_id / _name (71, 74)
#   CLIENT_HOST / _OS_USER   the connect block's CNCT_host / CNCT_user
#   WIRE_ENCRYPTED           TRUE under isql's default ChaCha64
#   MON$CLIENT_VERSION       the dpb's isc_dpb_client_version (80)
# The ids, ports and pids differ between the twins, so a cell compares
# what they EQUAL, not what they are. Still recorded (a transaction has
# no id here before its first write): CURRENT_TRANSACTION, TRANSACTION_ID.
#
#   qa/serve-real-session.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4616}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/sess-eng.fdb"; FC="$D/sess-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER, C BIGINT);
INSERT INTO T VALUES (1, NULL);
CREATE TABLE Q (\"USER\" INTEGER, \"CURRENT_ROLE\" VARCHAR(5));
INSERT INTO Q VALUES (1, 'r');
INSERT INTO Q VALUES (2, 'NONE');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/sess-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/sess-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-sess-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "SELECT 'SENTINEL' AS S FROM RDB\$DATABASE;\n%s\n" "$2" \
    | timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -a -v '^$' | sed -E 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() { # <label> <sql>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "${e#*SENTINEL}" = "$e" ]; then echo "FAIL $1 [the cell never ran: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [${e#*SENTINEL|}]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
rec() { # <label> <sql> <engine> <this server>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); e=${e#*SENTINEL|}; c=$(run "127.0.0.1/$PORT:$FC" "$2"); c=${c#*SENTINEL|}
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}
dsc() { printf 'SET SQLDA_DISPLAY ON;\nSET PLANONLY;\n%s\n' "$2" | timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -aE 'sqltype|name:|Statement failed|SQLSTATE' | sed 's/  */ /g' | paste -sd'|'; }
dboth() {
    ran=$((ran + 1))
    local e c
    e=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); c=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$e" ]; then echo "FAIL $1 [the cell never ran]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
GC() { echo "RDB\$GET_CONTEXT('SYSTEM', '$1')"; }
ME="FROM MON\$ATTACHMENTS WHERE MON\$ATTACHMENT_ID = CURRENT_CONNECTION"

echo "--- 1 CURRENT_CONNECTION is a value"
both "1 it is this row of MON\$ATTACHMENTS" "SELECT COUNT(*) AS N $ME;"
both "1 it is SESSION_ID" "SELECT CAST($(GC SESSION_ID) AS BIGINT) = CURRENT_CONNECTION AS E FROM RDB\$DATABASE;"
both "1 positive, in arithmetic, in a WHERE" "SELECT CURRENT_CONNECTION > 0 AS P, CURRENT_CONNECTION - CURRENT_CONNECTION AS Z FROM T WHERE CURRENT_CONNECTION IS NOT NULL;"
both "1 stored by an UPDATE, read back" "UPDATE T SET C = CURRENT_CONNECTION; SELECT C = CURRENT_CONNECTION AS E FROM T; ROLLBACK;"
both "1 lower case, in a CASE" "select case when current_connection = current_connection then 'same' end as s from rdb\$database;"
dboth "1 describe: BIGINT NOT NULL, named CURRENT_CONNECTION; arithmetic is ADD" \
      "SELECT CURRENT_CONNECTION, CURRENT_CONNECTION + 1 AS A FROM RDB\$DATABASE;"
both "1 a delimited \"CURRENT_CONNECTION\" is a column name" "SELECT \"CURRENT_CONNECTION\" FROM RDB\$DATABASE;"

echo "--- 1b a session keyword in a search condition is a value (it read as a column)"
both "1b WHERE MON\$ATTACHMENT_ID = CURRENT_CONNECTION" "SELECT COUNT(*) AS N FROM MON\$ATTACHMENTS WHERE MON\$ATTACHMENT_ID = CURRENT_CONNECTION;"
both "1b WHERE CURRENT_USER = 'SYSDBA', USER, lower case" \
     "SELECT ID FROM T WHERE CURRENT_USER = 'SYSDBA' AND user STARTING WITH 'SYS';"
both "1b WHERE CURRENT_ROLE" "SELECT ID FROM T WHERE CURRENT_ROLE = 'NONE';"
both "1b in a join's ON" \
     "SELECT COUNT(*) AS N FROM T JOIN RDB\$DATABASE ON CURRENT_CONNECTION > 0 AND CURRENT_USER = 'SYSDBA';"
both "1b CONTROL a delimited \"USER\" / \"CURRENT_ROLE\" is a column" \
     "SELECT \"USER\" FROM Q WHERE \"USER\" = 2 OR \"CURRENT_ROLE\" = 'r' ORDER BY 1;"
both "1b CONTROL ... beside the keyword" "SELECT \"USER\" FROM Q WHERE \"CURRENT_ROLE\" = CURRENT_ROLE;"

echo "--- 2 the session's SYSTEM keys agree with the monitoring tables"
both "2 DB_NAME is MON\$DATABASE_NAME" "SELECT $(GC DB_NAME) = MON\$DATABASE_NAME AS E FROM MON\$DATABASE;"
both "2 CLIENT_ADDRESS is MON\$REMOTE_ADDRESS, 127.0.0.1/<port>" \
     "SELECT $(GC CLIENT_ADDRESS) = MON\$REMOTE_ADDRESS AS E, $(GC CLIENT_ADDRESS) STARTING WITH '127.0.0.1/' AS L $ME;"
both "2 CLIENT_PID is MON\$REMOTE_PID, and positive" \
     "SELECT CAST($(GC CLIENT_PID) AS BIGINT) = MON\$REMOTE_PID AS E, MON\$REMOTE_PID > 0 AS P $ME;"
both "2 CLIENT_PROCESS / CLIENT_HOST / CLIENT_OS_USER (the same isql, host and user)" \
     "SELECT $(GC CLIENT_PROCESS) AS PR, $(GC CLIENT_HOST) = MON\$REMOTE_HOST AS H, $(GC CLIENT_OS_USER) = MON\$REMOTE_OS_USER AS U $ME;"
both "2 WIRE_ENCRYPTED / WIRE_CRYPT_PLUGIN / WIRE_COMPRESSED" \
     "SELECT $(GC WIRE_ENCRYPTED) AS E, $(GC WIRE_CRYPT_PLUGIN) AS P, $(GC WIRE_COMPRESSED) AS C FROM RDB\$DATABASE;"

echo "--- 3 MON\$ATTACHMENTS: the client's own words"
both "3 process, OS user, the wire" \
     "SELECT MON\$REMOTE_PROCESS, MON\$REMOTE_OS_USER, MON\$WIRE_ENCRYPTED, MON\$WIRE_CRYPT_PLUGIN, MON\$WIRE_COMPRESSED $ME;"
both "3 host and client version are set" \
     "SELECT MON\$REMOTE_HOST IS NOT NULL AS H, MON\$CLIENT_VERSION AS V, MON\$REMOTE_PROTOCOL AS P $ME;"

echo "--- 4 a client that says less (node-firebird: no crypt, no process name)"
nq() { FC_Q="$1" FC_PORT="$2" FC_DB="$3" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,[],(e2,rows)=>{
      console.log(e2?("ERR "+e2.message.replace(/\s+/g," ")):JSON.stringify(rows));db.detach();process.exit(0);});
  });' 2>/dev/null; }
nboth() {
    ran=$((ran + 1))
    local e c
    e=$(nq "$2" "$REAL" "$ENG"); c=$(nq "$2" "$PORT" "$FC")
    if [ -z "$e" ] || [ "$e" = CONN_ERR ] || [ "$c" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
if command -v node >/dev/null 2>&1 && node -e 'require("node-firebird")' 2>/dev/null; then
    nboth "4 node: the keys a client leaves unsaid" \
        "SELECT $(GC CLIENT_PID) IS NULL AS NP, $(GC CLIENT_PROCESS) AS PR, $(GC WIRE_ENCRYPTED) AS E, $(GC WIRE_CRYPT_PLUGIN) AS WP, CAST($(GC SESSION_ID) AS BIGINT) = CURRENT_CONNECTION AS S FROM RDB\$DATABASE"
    nboth "4 node: its MON\$ATTACHMENTS row" \
        "SELECT MON\$REMOTE_PID IS NULL AS NP, MON\$REMOTE_PROCESS AS PR, MON\$CLIENT_VERSION AS V, MON\$WIRE_ENCRYPTED AS E $ME"
else
    echo "SKIP section 4: node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"
fi

echo "--- 5 RECORDED: a transaction has no id here before its first write"
rec "5 RECORDED CURRENT_TRANSACTION" "SELECT CURRENT_TRANSACTION > 0 AS P FROM RDB\$DATABASE;" \
    ' P|=======|<true>|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
both "5 (promoted 2026-10-04) a HAVING over a session keyword" \
    "SELECT COUNT(*) AS N FROM T GROUP BY ID HAVING CURRENT_USER = 'SYSDBA' AND CURRENT_CONNECTION > 0;"
rec "5 RECORDED TRANSACTION_ID" "SELECT $(GC TRANSACTION_ID) IS NOT NULL AS P FROM RDB\$DATABASE;" \
    ' P|=======|<true>|' ' P|=======|<false>|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-sess-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 26 on the 2026-10-04 binary, 26 OK
if [ "$ran" -lt 26 ]; then echo "FAIL only $ran checks ran (floor 26) - cells went missing"; fail=1; fi
exit $fail
