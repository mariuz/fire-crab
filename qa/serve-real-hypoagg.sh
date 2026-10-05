#!/bin/bash
# THE HYPOTHETICAL-SET AGGREGATES: `RANK(v, ..) WITHIN GROUP (ORDER BY k,
# ..)`, DENSE_RANK, PERCENT_RANK and CUME_DIST - where the row (v, ..)
# would place among the group's rows. All four refused here (the paper's
# samples/nodejs/windows.js: `RANK(175) WITHIN GROUP (ORDER BY amount)`).
#
# Measured on 6.0.0.2196:
#   RANK          1 + the rows before the hypothetical row     BIGINT
#   DENSE_RANK    1 + the distinct key tuples before it        BIGINT
#   PERCENT_RANK  (RANK - 1) / n, 0 over no row                DOUBLE
#   CUME_DIST     (rows before or tied + 1) / (n + 1)          DOUBLE
#   all four NOT NULL, named RANK_AGG .. CUME_DIST_AGG
# THE NULL LAW (the engine's own, not the textbook's): under the
# direction's DEFAULT placement (ASC NULLS FIRST, DESC NULLS LAST, written
# or not) a NULL is a PEER of the ZERO value - 0, '', blanks, FALSE, DATE
# '1858-11-17' - and otherwise sorts at its default end (RANK(0) over
# {300, NULL, 400} is 1, RANK(-5) is 2; DENSE_RANK counts a NULL and a 0
# as ONE value); under the other placement a NULL sits at that end and is
# the peer of nothing but a NULL.
#
#   qa/serve-real-hypoagg.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4623}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/hypo-eng.fdb"; FC="$D/hypo-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE S (ID INT, R VARCHAR(5), A NUMERIC(10,2), V VARCHAR(5), CI VARCHAR(5) COLLATE UNICODE_CI, DF DECFLOAT(16));
INSERT INTO S VALUES (1,'E',100,'b','b',1);INSERT INTO S VALUES (2,'E',200,'a','A',2);
INSERT INTO S VALUES (3,'E',150,'c','c',3);INSERT INTO S VALUES (7,'E',150,'c','C',3);
INSERT INTO S VALUES (4,'W',300,'x','x',4);INSERT INTO S VALUES (5,'W',NULL,NULL,NULL,NULL);INSERT INTO S VALUES (6,'W',400,'y','y',5);
CREATE TABLE Y (K INT, T VARCHAR(5), TS TIMESTAMP, B BOOLEAN, D DATE, DB DOUBLE PRECISION);
INSERT INTO Y VALUES (NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO Y VALUES (0, '', TIMESTAMP '2024-01-01 10:00:00', TRUE, DATE '2024-01-01', 0);
INSERT INTO Y VALUES (3, 'b', NULL, FALSE, NULL, 2.5);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/hypo-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/hypo-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-hypo-$PORT.log" 2>&1 & srv=$!
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

echo "--- 1 the paper's sample, as written"
both "1 windows.js: a median and the rank of a 175 sale, per region" \
"SELECT R, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY A) AS MEDIAN, RANK(175) WITHIN GROUP (ORDER BY A) AS RANK_OF_175 FROM S GROUP BY R ORDER BY R;"

echo "--- 2 the four folds, per group, both directions"
both "2 RANK / DENSE_RANK / PERCENT_RANK / CUME_DIST of 150" \
"SELECT R, RANK(150) WITHIN GROUP (ORDER BY A) RK, DENSE_RANK(150) WITHIN GROUP (ORDER BY A) DR, PERCENT_RANK(150) WITHIN GROUP (ORDER BY A) PR, CUME_DIST(150) WITHIN GROUP (ORDER BY A) CD FROM S GROUP BY R ORDER BY R;"
both "2 ... DESC" \
"SELECT R, RANK(160) WITHIN GROUP (ORDER BY A DESC) RK, DENSE_RANK(160) WITHIN GROUP (ORDER BY A DESC) DR, CUME_DIST(160) WITHIN GROUP (ORDER BY A DESC) CD FROM S GROUP BY R ORDER BY R;"
both "2 two keys, a text key, past the end" \
"SELECT RANK(150, 'c') WITHIN GROUP (ORDER BY A, V) RK2, RANK('b') WITHIN GROUP (ORDER BY V) RV, RANK(999) WITHIN GROUP (ORDER BY A) RHI FROM S;"
both "2 over no row: 1, 1, 0, 1" \
"SELECT RANK(150) WITHIN GROUP (ORDER BY A) RK, DENSE_RANK(1) WITHIN GROUP (ORDER BY A) DR, PERCENT_RANK(150) WITHIN GROUP (ORDER BY A) PR, CUME_DIST(150) WITHIN GROUP (ORDER BY A) CD FROM S WHERE 1 = 0;"
both "2 in an expression, a CAST and a HAVING" \
"SELECT R, RANK(150) WITHIN GROUP (ORDER BY A) + 1 AS P, CAST(PERCENT_RANK(150) WITHIN GROUP (ORDER BY A) AS NUMERIC(5,2)) AS Q FROM S GROUP BY R HAVING RANK(150) WITHIN GROUP (ORDER BY A) > 1 ORDER BY R;"
both "2 expression keys, a DOUBLE literal, an exact one" \
"SELECT RANK(1) WITHIN GROUP (ORDER BY K + 1) RE, RANK(1) WITHIN GROUP (ORDER BY -K) RN, RANK(2.5) WITHIN GROUP (ORDER BY K) RD, RANK(1e0) WITHIN GROUP (ORDER BY K) RF, RANK(2.5) WITHIN GROUP (ORDER BY DB) RDB FROM Y;"
both "2 beside COUNT, lower case" \
"select r, count(*) c, rank(150) within group (order by a) rk from s group by r order by r;"
dboth "2 describe: BIGINT, BIGINT, DOUBLE, DOUBLE, all NOT NULL" \
"SELECT RANK(150) WITHIN GROUP (ORDER BY A) RK, DENSE_RANK(150) WITHIN GROUP (ORDER BY A), PERCENT_RANK(150) WITHIN GROUP (ORDER BY A) PR, CUME_DIST(150) WITHIN GROUP (ORDER BY A) CD FROM S;"

echo "--- 3 THE NULL LAW"
both "3 a NULL hypothetical row, each placement" \
"SELECT R, RANK(NULL) WITHIN GROUP (ORDER BY A) RK, RANK(NULL) WITHIN GROUP (ORDER BY A DESC) RKD, RANK(NULL) WITHIN GROUP (ORDER BY A NULLS LAST) RKL FROM S GROUP BY R ORDER BY R;"
both "3 the non-default placements" \
"SELECT R, RANK(350) WITHIN GROUP (ORDER BY A NULLS LAST) RK, RANK(350) WITHIN GROUP (ORDER BY A DESC NULLS FIRST) RKD FROM S GROUP BY R ORDER BY R;"
both "3 a NULL row is the peer of 0 and precedes everything else (default ASC)" \
"SELECT RANK(-5) WITHIN GROUP (ORDER BY A) M5, RANK(-5) WITHIN GROUP (ORDER BY A NULLS FIRST) M5NF, RANK(0) WITHIN GROUP (ORDER BY A) Z, RANK(0.00) WITHIN GROUP (ORDER BY A) Z2, RANK(0e0) WITHIN GROUP (ORDER BY A) ZF, RANK(1) WITHIN GROUP (ORDER BY A) O FROM S WHERE R = 'W';"
both "3 ... and of 0 under DESC NULLS LAST, never under DESC NULLS FIRST" \
"SELECT RANK(0) WITHIN GROUP (ORDER BY A DESC) ZD, RANK(0) WITHIN GROUP (ORDER BY A DESC NULLS FIRST) ZDNF, CUME_DIST(0) WITHIN GROUP (ORDER BY A DESC) CZD, RANK(-5) WITHIN GROUP (ORDER BY A DESC) M5D FROM S WHERE R = 'W';"
both "3 text: the peer of '' and of blanks, not under NULLS LAST" \
"SELECT RANK('') WITHIN GROUP (ORDER BY V) E, RANK(' ') WITHIN GROUP (ORDER BY V) SP, RANK('a') WITHIN GROUP (ORDER BY V) A1, RANK('a') WITHIN GROUP (ORDER BY V NULLS LAST) ANL FROM S WHERE R = 'W';"
both "3 DENSE_RANK counts a NULL and a 0 as one value; CUME_DIST ties them" \
"SELECT DENSE_RANK(5) WITHIN GROUP (ORDER BY K) D5, RANK(5) WITHIN GROUP (ORDER BY K) R5, CUME_DIST(0) WITHIN GROUP (ORDER BY K) C0, DENSE_RANK(1) WITHIN GROUP (ORDER BY K) D1, DENSE_RANK('c') WITHIN GROUP (ORDER BY T) DT FROM Y;"
both "3 TIMESTAMP and BOOLEAN keys (FALSE is the zero)" \
"SELECT RANK(TIMESTAMP '2024-01-01 00:00:00') WITHIN GROUP (ORDER BY TS) RT, RANK(TRUE) WITHIN GROUP (ORDER BY B) RB, RANK(FALSE) WITHIN GROUP (ORDER BY B) RBF FROM Y;"
both "3 a DATE key: the zero DATE is 1858-11-17" \
"SELECT RANK(DATE '2000-01-01') WITHIN GROUP (ORDER BY D) DD, RANK(DATE '1858-11-17') WITHIN GROUP (ORDER BY D) DZ, RANK(CAST(NULL AS DATE)) WITHIN GROUP (ORDER BY D) DN FROM Y;"
both "3 a NULL hypothetical row against a 0 row" \
"SELECT RANK(NULL) WITHIN GROUP (ORDER BY K) NK, RANK(NULL) WITHIN GROUP (ORDER BY K DESC) NKD, RANK(NULL) WITHIN GROUP (ORDER BY T) NT, RANK(NULL) WITHIN GROUP (ORDER BY T NULLS LAST) NTL FROM Y;"

echo "--- 4 CONTROLS - the window functions keep their own names"
both "4 RANK() / DENSE_RANK() / PERCENT_RANK() / CUME_DIST() OVER" \
"SELECT ID, RANK() OVER (ORDER BY A) RK, DENSE_RANK() OVER (ORDER BY A) DR, PERCENT_RANK() OVER (ORDER BY A) PR, CUME_DIST() OVER (ORDER BY A) CD FROM S ORDER BY ID;"
both "4 a PERCENTILE beside a plain aggregate" \
"SELECT R, COUNT(*) C, PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY A) M FROM S GROUP BY R ORDER BY R;"

echo "--- 5 RECORDED: shapes this server still refuses"
rec "5 RECORDED a value count that is not the key count: the engine raises at EXECUTE, after the describe" \
    "SELECT RANK(1, 2) WITHIN GROUP (ORDER BY K) BAD FROM Y;" \
    ' BAD|=====================|Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-Number of arguments of hypothetical-set aggregate function RANK must match number of sort items in WITHIN GROUP clause|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-Number of arguments of hypothetical-set aggregate function RANK must match number of sort items in WITHIN GROUP clause|'
rec "5 RECORDED a per-row value: the engine's -104 argmustbe_const_within_group" \
    "SELECT RANK(K) WITHIN GROUP (ORDER BY K) RK FROM Y;" \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Argument for RANK function must be constant within each group|' \
    'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
rec "5 RECORDED a text value for an INTEGER key (the engine converts it)" \
    "SELECT RANK('2') WITHIN GROUP (ORDER BY K) RS FROM Y;" \
    ' RS|=====================| 3|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
rec "5 RECORDED a key under a real collation (the engine answers 8 - every row before 'b' - not modelled)" \
    "SELECT RANK('b') WITHIN GROUP (ORDER BY CI) RC FROM S;" \
    ' RC|=====================| 8|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'
rec "5 RECORDED a DECFLOAT key" \
    "SELECT RANK(3) WITHIN GROUP (ORDER BY DF) RDF FROM S;" \
    ' RDF|=====================| 4|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-hypo-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 26 on the 2026-10-05 binary, 26 OK
if [ "$ran" -lt 26 ]; then echo "FAIL only $ran checks ran (floor 26) - cells went missing"; fail=1; fi
exit $fail
