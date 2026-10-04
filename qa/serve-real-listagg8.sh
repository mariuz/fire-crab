#!/bin/bash
# LISTAGG .. WITHIN GROUP UNDER A UTF8 DATABASE. Every other LISTAGG gate
# runs a NONE database, where a text key's ttype is 0; under UTF8 a
# VARCHAR key's ttype is 4 (UTF8, its DEFAULT collation) and a NUMERIC
# key's descriptor sub_type is 1 - both read as "a real collation" and
# refused at prepare, so the paper's samples/nodejs/windows.js (`CAST(
# LISTAGG(amount, ',') WITHIN GROUP (ORDER BY amount) AS VARCHAR(60))`
# GROUP BY region) answered a bare Dynamic SQL Error. A non-text key has
# no collation, and a text key in the default collation of NONE / OCTETS /
# ASCII / UNICODE_FSS / UTF8 sorts in code-point order - the value order.
#
# DISTINCT WITH WITHIN GROUP (measured on 2196, refused here before): the
# keys are NOT sort keys. The list is in VALUE order, DESCENDING only when
# the FIRST key is the argument itself (a qualified spelling, or the same
# expression) and says DESC; any other key - ID, UPPER(V), another
# column, a second key - is ignored.
#
#   qa/serve-real-listagg8.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4614}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/lagg8-eng.fdb"; FC="$D/lagg8-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE S (ID INTEGER, R VARCHAR(10), A NUMERIC(10,2), V VARCHAR(5), C CHAR(3),
  W VARCHAR(5) CHARACTER SET WIN1252, CI VARCHAR(5) COLLATE UNICODE_CI, D DOUBLE PRECISION, T DATE);
INSERT INTO S VALUES (1, 'E', 200, 'b', 'b', 'b', 'b', 2.5, DATE '2024-03-01');
INSERT INTO S VALUES (2, 'E', 100, 'a', 'a', 'a', 'A', 1.5, DATE '2024-01-01');
INSERT INTO S VALUES (3, 'E', 150, 'b', 'b', 'b', 'B', -1, DATE '2024-02-01');
INSERT INTO S VALUES (4, 'E', 250, 'c', 'c', 'c', 'c', NULL, NULL);
INSERT INTO S VALUES (5, 'E', NULL, NULL, NULL, NULL, NULL, 0, DATE '2023-01-01');
INSERT INTO S VALUES (6, 'W', 300, 'x', 'x', 'x', 'x', 9, DATE '2025-01-01');
INSERT INTO S VALUES (7, 'W', 50, 'y', 'y', 'y', 'y', 8, DATE '2022-01-01');
INSERT INTO S VALUES (8, 'W', 400, 'Ж', 'Ж', NULL, 'Ж', 7, DATE '2021-01-01');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/lagg8-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/lagg8-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-lagg8-$PORT.log" 2>&1 & srv=$!
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
L() { echo "CAST($1 AS VARCHAR(60))"; }

echo "--- 1 the paper's sample, as written"
both "1 windows.js: COUNT, a FILTER, a cast LISTAGG and a STDDEV per group" \
"SELECT R, COUNT(*) AS N, COUNT(*) FILTER (WHERE A > 150) AS BIG, CAST(LISTAGG(A, ',') WITHIN GROUP (ORDER BY A) AS VARCHAR(60)) AS AMOUNTS, CAST(STDDEV_POP(A) AS NUMERIC(10,2)) AS SD FROM S GROUP BY R ORDER BY R;"

echo "--- 2 every key type sorts by value under UTF8"
for k in "V" "V DESC" "A" "A DESC" "C" "D" "D DESC NULLS FIRST" "T" "T DESC" "R, V DESC" "S.V" "UPPER(V) DESC" "V || 'z'" "A * -1"; do
    both "2 ungrouped ORDER BY $k" "SELECT $(L "LISTAGG(ID, '-') WITHIN GROUP (ORDER BY $k)") AS L FROM S;"
done
for k in "V" "A DESC" "C DESC" "T"; do
    both "2 grouped ORDER BY $k" "SELECT R, $(L "LISTAGG(V, '-') WITHIN GROUP (ORDER BY $k)") AS L FROM S GROUP BY R ORDER BY R;"
done
both "2 the blob itself, uncast" "SELECT R, LISTAGG(V, ';') WITHIN GROUP (ORDER BY V DESC) AS L FROM S GROUP BY R ORDER BY R;"
both "2 LIST spelled LIST" "SELECT $(L "LIST(V) WITHIN GROUP (ORDER BY A DESC)") AS L FROM S;"
both "2 a WITHIN GROUP over no row" "SELECT $(L "LISTAGG(V) WITHIN GROUP (ORDER BY V)") AS L FROM S WHERE 1 = 0;"
dboth "2 describe" "SELECT LISTAGG(V, ',') WITHIN GROUP (ORDER BY V) AS L, LISTAGG(A) WITHIN GROUP (ORDER BY A) AS M FROM S;"

echo "--- 3 DISTINCT: value order, descending only by the argument's own DESC key"
for k in "V DESC" "V" "S.V DESC" "V DESC, ID" "V DESC NULLS FIRST" "ID" "ID DESC" "ID, V DESC" "UPPER(V) DESC" "R DESC"; do
    both "3 LISTAGG(DISTINCT V) ORDER BY $k" "SELECT $(L "LISTAGG(DISTINCT V, '-') WITHIN GROUP (ORDER BY $k)") AS L FROM S;"
done
both "3 the same expression" "SELECT $(L "LISTAGG(DISTINCT 'k' || V, '-') WITHIN GROUP (ORDER BY 'k' || V DESC)") AS L FROM S;"
both "3 a numeric argument, its own key" "SELECT $(L "LISTAGG(DISTINCT -ID, '-') WITHIN GROUP (ORDER BY -ID DESC)") AS L FROM S;"
both "3 ... another key" "SELECT $(L "LISTAGG(DISTINCT -ID, '-') WITHIN GROUP (ORDER BY ID DESC)") AS L FROM S;"
both "3 a NUMERIC argument descending" "SELECT $(L "LISTAGG(DISTINCT A) WITHIN GROUP (ORDER BY A DESC)") AS L FROM S;"
both "3 a CHAR argument descending (the byte image)" "SELECT $(L "LISTAGG(DISTINCT C, '/') WITHIN GROUP (ORDER BY C DESC)") AS L FROM S;"
both "3 per group" "SELECT R, $(L "LISTAGG(DISTINCT V, '-') WITHIN GROUP (ORDER BY V DESC)") AS L FROM S GROUP BY R ORDER BY R;"

echo "--- 4 RECORDED boundaries this server still refuses"
rec "4 RECORDED a WIN1252 key (byte order is not code-point order)" \
    "SELECT $(L "LISTAGG(ID) WITHIN GROUP (ORDER BY W)") AS L FROM S;" \
    'L|============================================================|5,8,2,1,3,4,6,7|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
rec "4 RECORDED a UNICODE_CI key" \
    "SELECT $(L "LISTAGG(ID) WITHIN GROUP (ORDER BY CI)") AS L FROM S;" \
    'L|============================================================|5,2,1,3,4,6,7,8|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
rec "4 RECORDED a DISTINCT UNICODE_CI argument descending" \
    "SELECT $(L "LISTAGG(DISTINCT CI) WITHIN GROUP (ORDER BY CI DESC)") AS L FROM S;" \
    'L|============================================================|Ж,y,x,c,B,A|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'

echo "--- 5 CONTROLS"
both "5 an INTEGER key, a NONE-free table" "SELECT $(L "LISTAGG(V) WITHIN GROUP (ORDER BY ID DESC)") AS L FROM S;"
both "5 DISTINCT without WITHIN GROUP" "SELECT $(L "LISTAGG(DISTINCT V, '-')") AS L FROM S;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-lagg8-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 45 on the 2026-10-04 binary, 45 OK
if [ "$ran" -lt 45 ]; then echo "FAIL only $ran checks ran (floor 45) - cells went missing"; fail=1; fi
exit $fail
