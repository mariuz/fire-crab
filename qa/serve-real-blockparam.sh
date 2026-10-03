#!/bin/bash
# EXECUTE BLOCK WITH INPUT PARAMETERS - `EXECUTE BLOCK (X INTEGER = ?,
# S VARCHAR(10) = ?) [RETURNS (..)] AS ..` - refused in EVERY form here,
# selectable and not, though the engine answers them all and a client
# reaches for them constantly (a parameterised script with no procedure
# to create).
#
# Each input is DECLARED WITH ITS TYPE and bound from a `?`, so it is
# exactly a procedure's input parameter: the block is compiled as the
# synthesized procedure it already was, now with those inputs; each slot
# is described as its declared type; and the bound value moves into it by
# the law a procedure argument moves by (bind_proc_args) - NULL, a text
# into an INTEGER, a conversion error, a SMALLINT overflow and a VARCHAR
# truncation all measured identical.  An input type the BLR compiler has
# no node for (DOUBLE PRECISION, FLOAT, BOOLEAN) is typed ON ITS OWN by the
# column-type reader, so one such input does not take the others' types
# down with it.  A typed BOOLEAN message had no argument arm at all
# (wireparam_arg_value) and refused as "unbound".
#
# Usage: qa/serve-real-blockparam.sh [port]   (default 4571)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4571}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/blockparam-eng.fdb"; FC="$D/blockparam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P';"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, V VARCHAR(20), N NUMERIC(9,2));
COMMIT;
INSERT INTO T VALUES (1, 'a', 1.50);
INSERT INTO T VALUES (2, 'b', 10);
INSERT INTO T VALUES (3, 'c', NULL);
COMMIT;
SET TERM ^;
CREATE FUNCTION F1 (X INTEGER) RETURNS INTEGER AS BEGIN RETURN X * 2; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/blockparam-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/blockparam-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/blockparam-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-blockparam-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
# the statement and a READ-BACK in ONE transaction that is ROLLED BACK, so
# a writing block leaves nothing for the next cell
qrb() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":(v instanceof Date?v.toISOString():v)).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r1)=>{
        const d=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("ok "+fmt(r1));
        tr.query(process.env.FC_RB,[],(e3,r)=>{tr.rollback(()=>{console.log(d+" | rb="+(e3?"ERR":fmt(r)));db.detach();process.exit(0);});});
      });
    });
  });' 2>/dev/null; }
# the input describe, through isql (it prints the INPUT message for a
# statement it cannot then bind)
dsc() { printf 'SET SQLDA_DISPLAY ON;\nSET TERM ^;\n%s^\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
RB0="SELECT 1 FROM RDB\$DATABASE"
both() { # <label> <sql> <json> [read-back]
    ran=$((ran + 1))
    local rb="${4:-$RB0}" ev fv ed fd
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$rb"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ] || [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$ev]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 [the ENGINE printed no describe]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1 (DESCRIBE)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
eng_only() { # the engine answers, this server refuses - recorded
    ran=$((ran + 1))
    local ev fv
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$RB0"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$RB0")
    if [ "${ev#ok}" = "$ev" ]; then echo "FAIL $1 - the ENGINE no longer answers [$ev]"; fail=1
    elif [ "${fv#ERR Dynamic SQL Error}" = "$fv" ]; then echo "FAIL $1 - this server moved [$fv]; promote if it matches [$ev]"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
EB="EXECUTE BLOCK"

echo "--- 1 a SELECTABLE block with inputs"
both "1 one INTEGER input"                 "$EB (X INTEGER = ?) RETURNS (Y INTEGER) AS BEGIN Y = X + 1; SUSPEND; END" '[41]'
both "1 two inputs, two types"             "$EB (X INTEGER = ?, S VARCHAR(10) = ?) RETURNS (R VARCHAR(30)) AS BEGIN R = S || X; SUSPEND; END" '[5,"ab"]'
both "1 an input in a FOR SELECT's WHERE"  "$EB (X INTEGER = ?) RETURNS (ID INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID > :X INTO :ID DO SUSPEND; END" '[1]'
both "1 a singleton SELECT INTO by input"  "$EB (K INTEGER = ?) RETURNS (V VARCHAR(20)) AS BEGIN SELECT V FROM T WHERE ID = :K INTO :V; SUSPEND; END" '[2]'
both "1 a loop bounded by an input"        "$EB (X INTEGER = ?) RETURNS (R INTEGER) AS DECLARE I INTEGER = 0; BEGIN WHILE (I < X) DO BEGIN I = I + 1; R = I; SUSPEND; END END" '[3]'
both "1 an input into a stored function"   "$EB (X INTEGER = ?) RETURNS (R INTEGER) AS BEGIN R = F1(X); SUSPEND; END" '[4]'
both "1 CONTROL no inputs (answered before)" "$EB RETURNS (Y INTEGER) AS BEGIN Y = 5; SUSPEND; END" '[]'

echo "--- 2 the input's DECLARED type is the slot, and the bound value moves into it as a procedure argument does"
both "2 NUMERIC(9,2) from text"            "$EB (N NUMERIC(9,2) = ?) RETURNS (R NUMERIC(9,2)) AS BEGIN R = N * 2; SUSPEND; END" '["1.25"]'
both "2 NUMERIC(9,2) from a double"        "$EB (N NUMERIC(9,2) = ?) RETURNS (R NUMERIC(9,2)) AS BEGIN R = N * 2; SUSPEND; END" '[1.25]'
both "2 DOUBLE PRECISION (typed by the column reader)" "$EB (D DOUBLE PRECISION = ?) RETURNS (R DOUBLE PRECISION) AS BEGIN R = D / 4; SUSPEND; END" '[3]'
both "2 FLOAT"                             "$EB (F FLOAT = ?) RETURNS (R FLOAT) AS BEGIN R = F * 2; SUSPEND; END" '[1.25]'
both "2 BOOLEAN true"                      "$EB (B BOOLEAN = ?) RETURNS (R VARCHAR(5)) AS BEGIN R = IIF(B, 'yes', 'no'); SUSPEND; END" '[true]'
both "2 BOOLEAN false - the IIF's CHAR(3) pad survives" "$EB (B BOOLEAN = ?) RETURNS (R VARCHAR(5)) AS BEGIN R = IIF(B, 'yes', 'no'); SUSPEND; END" '[false]'
both "2 DOUBLE beside VARCHAR - typed one by one" "$EB (D DOUBLE PRECISION = ?, S VARCHAR(5) = ?) RETURNS (R VARCHAR(30)) AS BEGIN R = S || D; SUSPEND; END" '[1.5,"v="]'
both "2 NUMERIC, BOOLEAN, VARCHAR"         "$EB (N NUMERIC(9,2) = ?, B BOOLEAN = ?, S VARCHAR(5) = ?) RETURNS (R VARCHAR(30)) AS BEGIN R = S || IIF(B, N, -N); SUSPEND; END" '["2.50",false,"x"]'
both "2 a NULL bind"                       "$EB (X INTEGER = ?) RETURNS (R INTEGER) AS BEGIN R = COALESCE(X, -1); SUSPEND; END" '[null]'
both "2 '12' into an INTEGER"              "$EB (X INTEGER = ?) RETURNS (R INTEGER) AS BEGIN R = X; SUSPEND; END" '["12"]'
both "2 'abc' into an INTEGER - the conversion error" "$EB (X INTEGER = ?) RETURNS (R INTEGER) AS BEGIN R = X; SUSPEND; END" '["abc"]'
both "2 70000 into a SMALLINT - out of range" "$EB (X SMALLINT = ?) RETURNS (R INTEGER) AS BEGIN R = X; SUSPEND; END" '[70000]'
both "2 'abcdef' into a VARCHAR(3) - truncation" "$EB (S VARCHAR(3) = ?) RETURNS (R VARCHAR(10)) AS BEGIN R = S; SUSPEND; END" '["abcdef"]'

echo "--- 3 a block WITHOUT RETURNS writes through its inputs (rolled back, read back)"
RB="SELECT ID, V, N FROM T ORDER BY ID"
both "3 UPDATE .. = :X"                    "$EB (X INTEGER = ?) AS BEGIN UPDATE T SET N = :X WHERE ID = 1; END" '[77]' "$RB"
both "3 UPDATE .. = :X [NULL]"             "$EB (X INTEGER = ?) AS BEGIN UPDATE T SET N = :X WHERE ID = 1; END" '[null]' "$RB"
both "3 INSERT two inputs"                 "$EB (K INTEGER = ?, S VARCHAR(20) = ?) AS BEGIN INSERT INTO T (ID, V) VALUES (:K, :S); END" '[9,"zz"]' "$RB"
both "3 DELETE by an input"                "$EB (K INTEGER = ?) AS BEGIN DELETE FROM T WHERE ID > :K; END" '[1]' "$RB"
both "3 a loop of INSERTs"                 "$EB (K INTEGER = ?) AS DECLARE I INTEGER = 0; BEGIN WHILE (I < K) DO BEGIN I = I + 1; INSERT INTO T (ID, V) VALUES (100 + :I, 'w'); END END" '[2]' "$RB"
both "3 a truncation leaves the row untouched" "$EB (S VARCHAR(2) = ?) AS BEGIN UPDATE T SET V = :S WHERE ID = 1; END" '["abc"]' "$RB"

echo "--- 4 RECORDED"
# a DATE input bound from TEXT: the procedure-argument law refuses a
# cross-type text into a temporal parameter by design (bind_proc_args)
eng_only "4 DATE input from text '2020-01-31'"     "$EB (DT DATE = ?) RETURNS (R DATE) AS BEGIN R = DT + 1; SUSPEND; END" '["2020-01-31"]'
# a stored FUNCTION called with a `?` - promoted the day it landed
# (`serve-real-fnparam.sh`); one in a WHERE is still a router of its own
both     "4 SELECT F1(?) - a PSQL function's argument (promoted with fnparam)" "SELECT F1(?) FROM RDB\$DATABASE" '[21]'
eng_only "4 WHERE F1(ID) > ?"                       "SELECT ID FROM T WHERE F1(ID) > ? ORDER BY ID" '[3]'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-blockparam-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 30 on the 2026-10-03 binary, 30 OK
if [ "$ran" -lt 30 ]; then echo "FAIL only $ran checks ran (floor 30) - cells went missing"; fail=1; fi
exit $fail
