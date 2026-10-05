#!/bin/bash
# A WINDOW FRAME'S EXCLUDE CLAUSE, and a frame on a ranking function.
#
# `.. ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW` refused
# here (the paper's samples/nodejs/windows.js: a neighbour average). The
# engine follows the standard, measured on 2196 over ROWS and RANGE frames,
# the folds and FIRST / LAST / NTH_VALUE: CURRENT ROW drops the row itself,
# GROUP the row and its ORDER BY peers, TIES the peers but not the row, NO
# OTHERS nothing; a frame the exclusion empties folds no rows (COUNT 0, AVG
# NULL); EXCLUDE is legal only after an explicit frame.
#
# A frame on ROW_NUMBER / RANK / DENSE_RANK / PERCENT_RANK / CUME_DIST /
# NTILE / LAG / LEAD refused here too; the engine IGNORES it (and its
# EXCLUDE) and answers as with none.
#
#   qa/serve-real-frameexclude.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4625}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/frex-eng.fdb"; FC="$D/frex-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE W (ID INT, G INT, K INT, A INT);
INSERT INTO W VALUES (1,1,10,1);INSERT INTO W VALUES (2,1,20,2);INSERT INTO W VALUES (3,1,20,4);
INSERT INTO W VALUES (4,1,30,8);INSERT INTO W VALUES (5,2,10,16);INSERT INTO W VALUES (6,2,10,32);
INSERT INTO W VALUES (7,2,NULL,64);
CREATE TABLE SALES (ID INT, REGION VARCHAR(10), AMOUNT NUMERIC(10,2));
INSERT INTO SALES VALUES (1,'East',100);INSERT INTO SALES VALUES (2,'East',200);INSERT INTO SALES VALUES (3,'East',150);
INSERT INTO SALES VALUES (4,'West',300);INSERT INTO SALES VALUES (5,'West',250);INSERT INTO SALES VALUES (6,'West',400);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/frex-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/frex-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-frex-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
# one statement, the whole output; a blob id is the instrument's, not the answer
run() { printf 'SET BLOB ALL;\nSELECT '"'"'SENTINEL'"'"' AS S FROM RDB$DATABASE;\n%s\n' "$2" \
    | timeout -s KILL 30 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -a -v '^$' | sed -E 's/  */ /g; s/ *$//; s/^ *[0-9a-f]+:[0-9a-f]+$/<blob>/; s/ [0-9a-f]+:[0-9a-f]+$/ <blob>/' | tr '\n' '|'; }
both() { # <label> <sql>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "${e#*SENTINEL}" = "$e" ]; then echo "FAIL $1 [the cell never ran: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [${e#*SENTINEL|}]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
# a RECORDED boundary: the engine's answer pinned, this server's clean
# refusal pinned - a cell that starts to agree FAILS, to be promoted
rec() { # <label> <sql> <engine> <this server>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); e=${e#*SENTINEL|}; c=$(run "127.0.0.1/$PORT:$FC" "$2"); c=${c#*SENTINEL|}
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}
dsc() { printf 'SET SQLDA_DISPLAY ON;\nSET PLANONLY;\n%s\n' "$2" | timeout -s KILL 30 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -aE 'sqltype|name:|Statement failed|SQLSTATE' | sed 's/  */ /g' | paste -sd'|'; }
dboth() {
    ran=$((ran + 1))
    local e c
    e=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); c=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$e" ]; then echo "FAIL $1 [the cell never ran]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
FR="ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING"
ALL="ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"

echo "--- 1 the paper's sample, as written"
both "1 windows.js: the neighbour average" \
"SELECT ID, AMOUNT, CAST(AVG(AMOUNT) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) AS NUMERIC(10,2)) AS NEIGHBOUR_AVG FROM SALES ORDER BY ID;"

echo "--- 2 the four exclusions over a ROWS frame"
both "2 CURRENT ROW / NO OTHERS" "SELECT ID, SUM(A) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) S1, SUM(A) OVER (ORDER BY ID $FR EXCLUDE NO OTHERS) S0 FROM W ORDER BY ID;"
both "2 GROUP / TIES over peers (K has ties and a NULL)" "SELECT ID, SUM(A) OVER (ORDER BY K $ALL EXCLUDE GROUP) SG, SUM(A) OVER (ORDER BY K $ALL EXCLUDE TIES) ST FROM W ORDER BY ID;"
both "2 per partition, DESC, lower case" "select id, sum(a) over (partition by g order by k desc rows between 1 preceding and unbounded following exclude ties) s from w order by id;"
both "2 the folds: an emptied frame is AVG NULL, COUNT 0" \
"SELECT ID, AVG(A) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND CURRENT ROW EXCLUDE CURRENT ROW) AV, COUNT(*) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND CURRENT ROW EXCLUDE GROUP) C0, MIN(A) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) MN, MAX(A) OVER (ORDER BY K $ALL EXCLUDE TIES) MX, COUNT(A) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) CN FROM W ORDER BY ID;"
both "2 FIRST / LAST / NTH_VALUE read the frame after the exclusion" \
"SELECT ID, FIRST_VALUE(A) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) FV, LAST_VALUE(A) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) LV, NTH_VALUE(A, 2) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) NV, NTH_VALUE(A, 1) FROM LAST OVER (ORDER BY K $ALL EXCLUDE GROUP) NL FROM W ORDER BY ID;"
both "2 the ROWS shorthand" "SELECT ID, SUM(A) OVER (ORDER BY ID ROWS 1 PRECEDING EXCLUDE CURRENT ROW) SH FROM W ORDER BY ID;"

echo "--- 3 over a RANGE frame"
both "3 an offset RANGE, CURRENT ROW excluded" "SELECT ID, SUM(A) OVER (ORDER BY K RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING EXCLUDE CURRENT ROW) RC FROM W ORDER BY ID;"
both "3 the peer group alone: TIES keeps the row, GROUP keeps nothing" \
"SELECT ID, SUM(A) OVER (ORDER BY K RANGE BETWEEN CURRENT ROW AND CURRENT ROW EXCLUDE TIES) RT, COUNT(*) OVER (ORDER BY K RANGE BETWEEN CURRENT ROW AND CURRENT ROW EXCLUDE GROUP) RG FROM W ORDER BY ID;"
both "3 the running RANGE, GROUP excluded" "SELECT ID, SUM(A) OVER (ORDER BY K RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE GROUP) RU FROM W ORDER BY ID;"

echo "--- 4 a frame on a ranking or navigation function is ignored"
for fn in "ROW_NUMBER()" "RANK()" "DENSE_RANK()" "PERCENT_RANK()" "CUME_DIST()" "NTILE(2)" "LAG(A)" "LEAD(A)"; do
    both "4 $fn under a ROWS frame, an EXCLUDE, a RANGE frame" \
    "SELECT ID, $fn OVER (ORDER BY ID $FR) X1, $fn OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) X2, $fn OVER (ORDER BY ID RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) X3 FROM W ORDER BY ID;"
done

echo "--- 5 CONTROLS - frames without EXCLUDE are as they were"
both "5 ROWS and RANGE frames, a default frame" "SELECT ID, SUM(A) OVER (ORDER BY ID $FR) S, SUM(A) OVER (ORDER BY K RANGE BETWEEN 10 PRECEDING AND CURRENT ROW) R, SUM(A) OVER (ORDER BY ID) D FROM W ORDER BY ID;"

echo "--- 6 RECORDED: the engine's own refusals, a bare one here"
rec "6 RECORDED EXCLUDE without a frame is the engine's -104 at EXCLUDE" \
    "SELECT ID, SUM(A) OVER (ORDER BY ID EXCLUDE CURRENT ROW) X FROM W;" \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 37|-EXCLUDE|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
rec "6 RECORDED LIST in a framed window is the engine's 0A000" \
    "SELECT ID, LIST(A) OVER (ORDER BY ID $FR EXCLUDE CURRENT ROW) L FROM W;" \
    'Statement failed, SQLSTATE = 0A000|feature is not supported|-LIST is not supported in windows with ORDER BY or frame by ROWS/GROUPS clauses|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-frex-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 22 on the 2026-10-05 binary, 22 OK
if [ "$ran" -lt 22 ]; then echo "FAIL only $ran checks ran (floor 22) - cells went missing"; fail=1; fi
exit $fail
