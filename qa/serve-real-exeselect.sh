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
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
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

echo "--- 4 DECLINED: the interpreter answers, right"
route "4 a text output (slice 1 types no text column)" declined "SELECT ID, S FROM T ORDER BY ID"
route "4 a DATE literal in the predicate (the BLR compiler takes none)" declined "SELECT ID FROM T WHERE D > DATE '2024-02-01' ORDER BY ID"
route "4 a CAST to TIMESTAMP (the executor has no such cast)" declined "SELECT CAST(D AS TIMESTAMP) FROM T ORDER BY ID"
route "4 a DOUBLE output" declined "SELECT CAST(N AS DOUBLE PRECISION) FROM T ORDER BY ID"

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
if [ "$ran" -lt 21 ]; then echo "FAIL only $ran checks ran (floor 21) - cells went missing"; fail=1; fi
exit $fail
