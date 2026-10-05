#!/bin/bash
# A SELECT SERVED BY THE BLR PATH - SQL -> fire-crab-dsql's BLR ->
# fire-crab-exe's record sources -> rows: item 3 of
# docs/full-conversion-plan.md, moving SQL execution out of `wire` one
# statement family at a time. The route is EXPERIMENTAL and off unless
# FC_EXEC_SELECT is set; this gate runs the server with it ON and holds
# every answer to the engine's.
#
# A cell proves TWO things: the rows are the engine's, AND the BLR path
# served them - the server's trace names each statement it served
# (`exe_select served`), so a cell the interpreter quietly answered (the
# route declining) cannot pass as a measurement of the executor. A
# `declined` cell pins the opposite: a shape the route must leave to the
# interpreter, still answered right.
#
# Slice 1: no parameters, every output an exact numeric or a temporal.
# Found on the way: fire-crab-exe ordered no DATE / TIME / TIMESTAMP - a
# sort called them equal and MIN / MAX kept the first (`MAX(D)` answered
# the earliest date); an unorderable pair of non-NULL values now FAILS the
# run instead (the caller falls back), and the temporal kinds order.
#
#   qa/serve-real-exeselect.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4649}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/exs-eng-$PORT.fdb"; FC="$D/exs-fc-$PORT.fdb"
LOG="/tmp/fc-serve-exs-$PORT.log"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INT PRIMARY KEY, N NUMERIC(9,2), B BIGINT, D DATE, TS TIMESTAMP, TM TIME, S VARCHAR(10), G SMALLINT);
INSERT INTO T VALUES (1, 1.50, 10, DATE '2024-01-02', TIMESTAMP '2024-01-02 10:00:00', TIME '10:00:00', 'abc', 1);
INSERT INTO T VALUES (2, -2.25, NULL, DATE '2024-03-04', TIMESTAMP '2023-12-31 23:59:59', TIME '09:30:00', 'xyz', 1);
INSERT INTO T VALUES (3, NULL, 30, NULL, NULL, NULL, NULL, 2);
INSERT INTO T VALUES (4, 7.00, 30, DATE '2023-06-15', TIMESTAMP '2024-01-02 09:59:59', TIME '23:00:00', 'abc', 2);
CREATE TABLE U (ID INT, T_ID INT, V NUMERIC(18,4));
INSERT INTO U VALUES (10, 1, 0.5);
INSERT INTO U VALUES (11, 1, 1.25);
INSERT INTO U VALUES (12, 4, -3);
CREATE TABLE W (ID INT, V VARCHAR(10) CHARACTER SET UTF8, K CHAR(3) CHARACTER SET UTF8);
INSERT INTO W VALUES (1, 'café', 'é');
INSERT INTO W VALUES (2, 'Zeta', 'ab');
INSERT INTO W VALUES (3, NULL, NULL);
INSERT INTO W VALUES (4, 'abc', 'ab');
CREATE TABLE X (ID INT, P VARCHAR(5) CHARACTER SET WIN1252);
INSERT INTO X VALUES (1, 'x');
CREATE VIEW VT AS SELECT ID, N FROM T WHERE ID < 3;
CREATE TABLE E (ID INT, N INT);
CREATE INDEX E_N ON E (N);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/exs-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/exs-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
FC_EXEC_SELECT=1 FC_EXEC_SELECT_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "$LOG" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -ch "${CS:-NONE}" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
# route <label> <served|declined> <one SELECT, no trailing ;>
route() {
    ran=$((ran + 1))
    local e c before after
    e=$(run "127.0.0.1/$REAL:$ENG" "$3;")
    before=$(grep -ac "exe_select served [0-9]* rows: \"$(printf '%s' "$3" | sed 's/[][\.*^$/]/\\&/g')\"" "$LOG")
    c=$(run "127.0.0.1/$PORT:$FC" "$3;")
    after=$(grep -ac "exe_select served [0-9]* rows: \"$(printf '%s' "$3" | sed 's/[][\.*^$/]/\\&/g')\"" "$LOG")
    local by; [ "$after" -gt "$before" ] && by=served || by=declined
    if [ "$e" != "$c" ]; then echo "DIFF $1 (the BLR path $by it)"; diff <(printf '%s\n' "$e") <(printf '%s\n' "$c") | head -12 | sed 's/^/     /'; fail=1
    elif [ "$by" != "$2" ]; then echo "FAIL $1 - the BLR path $by it, the cell says $2"; fail=1
    else echo "OK   $1 ($by)"; fi
}

echo "--- 1 one table: scan, filter, sort, limits"
route "1 a scan, exact numerics" served "SELECT ID, N, B, G FROM T ORDER BY ID"
route "1 a filter on a scaled column" served "SELECT ID FROM T WHERE N > 0 ORDER BY ID"
route "1 a sort DESC over a NUMERIC with NULLs" served "SELECT ID, N FROM T ORDER BY N DESC"
route "1 FIRST / SKIP" served "SELECT FIRST 2 SKIP 1 ID FROM T ORDER BY ID"
route "1 a text predicate, a numeric output" served "SELECT ID FROM T WHERE S = 'abc' ORDER BY ID"
route "1 an ORDER BY ordinal over computed outputs" served "SELECT ID * 2, N + 1 FROM T ORDER BY 1 DESC"
route "1 IS NULL / IN / BETWEEN" served "SELECT ID FROM T WHERE N IS NULL OR B IN (10, 99) OR ID BETWEEN 3 AND 4 ORDER BY ID"

echo "--- 2 the temporal kinds: ordered, compared, folded"
route "2 a DATE output sorted DESC" served "SELECT ID, D FROM T WHERE D IS NOT NULL ORDER BY D DESC"
route "2 MIN / MAX of a DATE, a TIMESTAMP, a TIME" served "SELECT MAX(D), MIN(D), MAX(TS), MIN(TS), MAX(TM), MIN(TM) FROM T"
route "2 a TIMESTAMP and a TIME sorted" served "SELECT ID, TS, TM FROM T ORDER BY TS, TM"

echo "--- 3 aggregates, grouping, joins"
route "3 COUNT / SUM / MAX over the table" served "SELECT COUNT(*), SUM(N), MAX(B), MIN(G) FROM T"
route "3 GROUP BY a SMALLINT, HAVING" served "SELECT G, COUNT(*), SUM(N) FROM T GROUP BY G HAVING COUNT(*) > 1 ORDER BY G"
route "3 an inner join, a NUMERIC(18,4) output" served "SELECT T.ID, U.V FROM T JOIN U ON U.T_ID = T.ID ORDER BY U.ID"
route "3 EXISTS" served "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.T_ID = T.ID) ORDER BY ID"

echo "--- 6 text outputs in their own set (slice 2)"
route "6 a NONE text output, sorted" served "SELECT ID, S FROM T ORDER BY S, ID"
CS=UTF8 route "6 UTF8 text outputs under a UTF8 attachment: VARCHAR / CHAR padding, sorted" served "SELECT ID, V, K FROM W ORDER BY V, ID"
CS=UTF8 route "6 MAX / MIN of text, a text predicate, GROUP BY text" served "SELECT MAX(V), MIN(K) FROM W"
CS=UTF8 route "6 ...a range over text" served "SELECT ID FROM W WHERE V > 'c' ORDER BY ID"
CS=UTF8 route "6 ...GROUP BY a CHAR" served "SELECT K, COUNT(*) FROM W GROUP BY K ORDER BY K"
CS=UTF8 route "6 ...LIKE / STARTING WITH" served "SELECT ID, V FROM W WHERE V STARTING WITH 'c' OR V LIKE 'Z%' ORDER BY 1"
route "6 UTF8 outputs under a NONE attachment" served "SELECT ID, V FROM W ORDER BY ID"

echo "--- 7 bound parameters (slice 3): each ? an input of the procedure, typed as the prepare described it"
if command -v node >/dev/null 2>&1 && node -e 'require("node-firebird")' 2>/dev/null; then
qmsg() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey",encoding:"UTF8"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
      console.log(e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("rows "+fmt(r)));
      db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
proute() { # <label> <served|declined> <sql> <json params>
    ran=$((ran + 1))
    local e c before after pat
    pat="exe_select served [0-9]* rows: \"$(printf '%s' "$3" | sed 's/[][\.*^$/]/\\&/g')\""
    e=$(qmsg "$REAL" "$ENG" "$3" "$4"); before=$(grep -ac "$pat" "$LOG")
    c=$(qmsg "$PORT" "$FC" "$3" "$4"); after=$(grep -ac "$pat" "$LOG")
    local by; [ "$after" -gt "$before" ] && by=served || by=declined
    case "$e$c" in *CONN_ERR*) echo "FAIL $1 - a connection died [$e] [$c]"; fail=1; return;; esac
    if [ "$e" != "$c" ]; then echo "DIFF $1 (the BLR path $by it)"; echo "     eng=[$e]"; echo "     fc =[$c]"; fail=1
    elif [ "$by" != "$2" ]; then echo "FAIL $1 - the BLR path $by it, the cell says $2"; fail=1
    else echo "OK   $1 ($by) [$e]"; fi
}
proute "7 an INTEGER parameter in a range" served "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[1]'
proute "7 two parameters, BETWEEN, an aggregate" served "SELECT COUNT(*), SUM(N) FROM T WHERE ID BETWEEN ? AND ?" '[2, 4]'
proute "7 a text parameter against a UTF8 column" served "SELECT ID, V FROM W WHERE V = ? ORDER BY ID" '["café"]'
proute "7 LIKE a parameter" served "SELECT ID FROM W WHERE V LIKE ? ORDER BY ID" '["%e%"]'
proute "7 a CHAR column's padding against a parameter" served "SELECT ID, K FROM W WHERE K = ? ORDER BY ID" '["ab"]'
proute "7 FIRST with a parameterised filter" served "SELECT FIRST 1 ID FROM T WHERE ID >= ? ORDER BY ID DESC" '[1]'
proute "7 a NULL bound" served "SELECT COUNT(*) FROM T WHERE N = ?" '[null]'
proute "7 a DATE parameter" served "SELECT ID FROM T WHERE D < ? ORDER BY ID" '["2024-02-01"]'
echo "--- 8 DECLINED bound values: the engine compares what the move would change"
proute "8 a fractional bound against an INTEGER slot - no row equals 2.4, the move made it 2" declined "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '["2.4"]'
proute "8 ...COALESCE of 1.25 described INTEGER - the executor kept the double and encoded 0" declined "SELECT COALESCE(?, 0) FROM T WHERE ID = 1" '[1.25]'
proute "8 a TIMESTAMP message into a TIME slot - the engine promotes the TIME to TODAY" declined "SELECT ID FROM T WHERE IIF(TM = ?, 1, 0) = 1 ORDER BY ID" '["2024-01-10 10:00:00"]'
proute "8 a negated parameter - the executor's negate cannot know the overflow" declined "SELECT ID FROM T WHERE -CAST(? AS INTEGER) = -2" '[2]'
proute "8 control: a whole number bound is served" served "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '[2]'
else echo "SKIP 7 node-firebird not resolvable"; fi

echo "--- 4 DECLINED: the interpreter answers, right"
route "4 a codepage relation (the executor orders by code point, WIN1252 by byte)" declined "SELECT ID FROM X ORDER BY ID"
route "4 a DATE literal in the predicate (the BLR compiler takes none)" declined "SELECT ID FROM T WHERE D > DATE '2024-02-01' ORDER BY ID"
route "4 a CAST to TIMESTAMP (the executor has no such cast)" declined "SELECT CAST(D AS TIMESTAMP) FROM T ORDER BY ID"
route "4 a DOUBLE output" declined "SELECT CAST(N AS DOUBLE PRECISION) FROM T ORDER BY ID"
echo "--- 9 system relations: their formats are built in, never stored (slice 4)"
route "9 a SYSTEM relation, numeric outputs" served "SELECT RDB\$RELATION_ID, RDB\$SYSTEM_FLAG FROM RDB\$RELATIONS WHERE RDB\$RELATION_ID < 12 ORDER BY 1"
route "9 ...an aggregate over one" served "SELECT COUNT(*), MAX(RDB\$FIELD_POSITION) FROM RDB\$RELATION_FIELDS WHERE RDB\$SYSTEM_FLAG = 0"
route "9 ...joined to a user table's count" served "SELECT COUNT(*) FROM RDB\$RELATIONS R JOIN RDB\$RELATION_FIELDS F ON F.RDB\$RELATION_NAME = R.RDB\$RELATION_NAME WHERE R.RDB\$SYSTEM_FLAG = 0"
route "9 a VIRTUAL relation declines (its rows are computed)" declined "SELECT MON\$PAGE_SIZE FROM MON\$DATABASE"
route "9 ...and a MON\$ column beside a numeric expression" declined "SELECT MON\$SQL_DIALECT + 0 FROM MON\$DATABASE"
route "4 a view joined to a table (the BLR's relation list names only the base: COUNT 0)" declined "SELECT COUNT(*) FROM VT JOIN U ON U.T_ID = VT.ID"
route "4 a text literal against an INTEGER over an EMPTY indexed table (the engine raises at compile)" declined "SELECT ID FROM E WHERE N = 'x'"

echo "--- 5 the BLR compiler: an ORDER BY ordinal is the item it names"
both() { ran=$((ran + 1)); local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$c" ]; then echo "OK   $1"; else echo "DIFF $1"; diff <(printf '%s\n' "$e") <(printf '%s\n' "$c") | head -12 | sed 's/^/     /'; fail=1; fi; }
both "5 CREATE PROCEDURE over FOR SELECT .. ORDER BY 2 DESC, 1 / an aggregate's 2 / an expression's 1 (refused before)" "SET TERM ^;
CREATE PROCEDURE PO1 RETURNS (R INT, Q NUMERIC(9,2)) AS BEGIN FOR SELECT ID, N FROM T ORDER BY 2 DESC, 1 INTO :R, :Q DO SUSPEND; END^
CREATE PROCEDURE PO3 RETURNS (R INT, Q BIGINT) AS BEGIN FOR SELECT G, COUNT(*) FROM T GROUP BY G ORDER BY 2 DESC, 1 INTO :R, :Q DO SUSPEND; END^
CREATE PROCEDURE PO5 RETURNS (R BIGINT) AS BEGIN FOR SELECT ID * 2 FROM T ORDER BY 1 DESC INTO :R DO SUSPEND; END^
SET TERM ;^
COMMIT;
SELECT * FROM PO1; SELECT * FROM PO3; SELECT * FROM PO5;"
rec() { ran=$((ran + 1)); local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '\n' '|'); c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi; }
rec "5 RECORDED an ordinal past the select list: the engine's -104 vector, a bare refusal here" "SET TERM ^;
CREATE PROCEDURE PO7 RETURNS (R INT) AS BEGIN FOR SELECT ID FROM T ORDER BY 2 INTO :R DO SUSPEND; END^
SET TERM ;^
ROLLBACK;" 'Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-CREATE PROCEDURE "PUBLIC"."PO7" failed|-Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause|X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|X|======|DONE|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "$LOG"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 48 ]; then echo "FAIL only $ran checks ran (floor 48) - cells went missing"; fail=1; fi
exit $fail
