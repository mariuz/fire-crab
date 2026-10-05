#!/bin/bash
# WRITING A TABLE THAT CARRIES AN EXPRESSION OR A PARTIAL INDEX.
#
# Every INSERT and UPDATE on such a table refused here - `CREATE INDEX ..
# COMPUTED BY (UPPER(T))` or `CREATE INDEX .. (S) WHERE S = 'active'`,
# both made by the engine, left the table read-only through this server,
# because the write path could not key them. They are now maintained from
# their catalog sources (RDB$EXPRESSION_SOURCE / RDB$CONDITION_SOURCE)
# through the statement resolver: an expression index keys the
# expression's value in the itype the index root records, a partial index
# holds only the rows its condition takes (an UPDATE that moves a row INTO
# the condition keys it), and neither drives a retrieval here.
#
# THE PROOF IS THE ENGINE'S: the same DML runs on twin files, then the
# ENGINE reads this server's file THROUGH THOSE INDEXES (each query's plan
# names one) and must answer what it answers over its own file, and
# `gfix -v -full` must find the file clean.
#
# Still refused (recorded): a UNIQUE expression index (its duplicate
# message names the expression), and an expression over a column of a real
# collation.
#
#   qa/serve-real-exprindex.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4628}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/xidx-eng-$PORT.fdb"; FC="$D/xidx-fc-$PORT.fdb"; VFY="$D/xidx-vfy-$PORT.fdb"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE D (ID INT, T VARCHAR(20), S VARCHAR(10), N INT);
CREATE INDEX D_U ON D COMPUTED BY (UPPER(T));
CREATE INDEX D_P ON D (S) WHERE S = 'active';
CREATE DESCENDING INDEX D_N2 ON D COMPUTED BY (N * 2);
CREATE INDEX D_PN ON D (N) WHERE N > 0 AND T IS NOT NULL;
CREATE TABLE M (ID INT NOT NULL PRIMARY KEY, T VARCHAR(20), DT DATE, K INT);
CREATE INDEX M_Y ON M COMPUTED BY (EXTRACT(YEAR FROM DT));
CREATE INDEX M_TT ON M COMPUTED BY (TRIM(T) || '!');
CREATE UNIQUE INDEX M_UK ON M (K) WHERE K > 100;
CREATE TABLE PL (ID INT, T VARCHAR(20));
CREATE INDEX PL_T ON PL (T);
CREATE TABLE UX (ID INT, T VARCHAR(10));
CREATE UNIQUE INDEX UX_U ON UX COMPUTED BY (UPPER(T));
CREATE TABLE CI (ID INT, T VARCHAR(10) COLLATE UNICODE_CI);
CREATE INDEX CI_X ON CI COMPUTED BY (T || 'x');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/xidx-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/xidx-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-xidx-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf '%s\n' "$2" | timeout -s KILL 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}

DML="INSERT INTO D VALUES (1, 'abc', 'active', 5);
INSERT INTO D VALUES (2, 'Déf', 'done', 7);
INSERT INTO D VALUES (3, NULL, NULL, NULL);
INSERT INTO D VALUES (4, 'abc', 'active', -3);
INSERT INTO D SELECT ID + 10, T || 'x', S, N + 1 FROM D;
UPDATE D SET T = 'xyz', S = 'active' WHERE ID = 2;
UPDATE D SET S = 'done' WHERE ID = 4;
UPDATE D SET N = 50 WHERE ID = 3;
DELETE FROM D WHERE ID = 11;
INSERT INTO D VALUES (11, 'ABC', 'active', 9);
INSERT INTO M VALUES (1, ' a ', DATE '2024-05-01', 5);
INSERT INTO M VALUES (2, 'b', DATE '2023-01-01', 200);
INSERT INTO M VALUES (3, 'c', NULL, 200);
INSERT INTO M VALUES (4, 'd', DATE '2024-02-02', 50);
INSERT INTO M VALUES (5, 'e', DATE '2024-02-02', 50);
UPDATE OR INSERT INTO M VALUES (4, 'dd', DATE '2022-02-02', 300) MATCHING (ID);
UPDATE OR INSERT INTO M VALUES (6, 'f', DATE '2021-01-01', 7) MATCHING (ID);
MERGE INTO M USING (SELECT 1 AS ID FROM RDB\$DATABASE UNION ALL SELECT 9 FROM RDB\$DATABASE) S ON M.ID = S.ID WHEN MATCHED THEN UPDATE SET T = 'merged', K = 300 WHEN NOT MATCHED THEN INSERT VALUES (S.ID, 'new', DATE '2020-01-01', 400);
UPDATE M SET K = 400 WHERE ID = 2;
INSERT INTO PL VALUES (1, 'p');
COMMIT;"
echo "--- 1 the same DML on both files: every statement answers alike"
check "1 INSERT, INSERT .. SELECT, UPDATE in and out of a condition, DELETE, UPDATE OR INSERT, MERGE, a partial UNIQUE" \
    "$(run "127.0.0.1/$REAL:$ENG" "$DML")" "$(run "127.0.0.1/$PORT:$FC" "$DML")"

echo "--- 2 the ENGINE reads this server's file through the indexes"
cp "$FC" "$VFY"; chmod 666 "$VFY"
for q in \
    "SELECT ID FROM D WHERE UPPER(T) = 'XYZ';" \
    "SELECT ID FROM D WHERE UPPER(T) STARTING WITH 'ABC' ORDER BY ID;" \
    "SELECT ID FROM D WHERE S = 'active' ORDER BY ID;" \
    "SELECT ID FROM D WHERE N * 2 > 0 ORDER BY ID;" \
    "SELECT ID FROM D WHERE N * 2 BETWEEN -10 AND 20 ORDER BY ID;" \
    "SELECT ID FROM D WHERE N > 0 AND T IS NOT NULL ORDER BY ID;" \
    "SELECT ID FROM D ORDER BY UPPER(T), ID;" \
    "SELECT ID FROM M WHERE EXTRACT(YEAR FROM DT) = 2024 ORDER BY ID;" \
    "SELECT ID FROM M WHERE TRIM(T) || '!' = 'a!' ORDER BY ID;" \
    "SELECT ID, K FROM M WHERE K > 100 ORDER BY K, ID;" \
    "SELECT ID, T, K FROM M ORDER BY ID;"; do
    check "2 $q" "$(run "127.0.0.1/$REAL:$ENG" "SET PLAN ON; $q")" "$(run "127.0.0.1/$REAL:$VFY" "SET PLAN ON; $q")"
done
ran=$((ran + 1))
if "$GFIX" -v -full -user "$U" -pas "$P" "127.0.0.1/$REAL:$VFY" > /tmp/xidx-gfix.log 2>&1 && [ ! -s /tmp/xidx-gfix.log ]; then
    echo "OK   2 gfix -v -full finds this server's file clean"
else echo "DIFF 2 gfix -v -full:"; sed 's/^/     /' /tmp/xidx-gfix.log | head; fail=1; fi

echo "--- 3 RECORDED: indexes whose writes still refuse here"
rec() { # <label> <sql> <engine> <this server>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | sed 's/  */ /g; s/ *$//' | tr '\n' '|')
    c=$(run "127.0.0.1/$PORT:$FC" "$2" | sed 's/  */ /g; s/ *$//' | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}
rec "3 RECORDED a UNIQUE expression index" "INSERT INTO UX VALUES (1, 'a'); SELECT COUNT(*) AS N FROM UX; ROLLBACK;" \
    ' N|=====================| 1|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error| N|=====================| 0|'
rec "3 RECORDED an expression over a UNICODE_CI column" "INSERT INTO CI VALUES (1, 'a'); SELECT COUNT(*) AS N FROM CI; ROLLBACK;" \
    ' N|=====================| 1|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error| N|=====================| 0|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-xidx-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 16 on the 2026-10-05 binary, 16 OK
if [ "$ran" -lt 16 ]; then echo "FAIL only $ran checks ran (floor 16) - cells went missing"; fail=1; fi
exit $fail
