#!/bin/bash
# A BLOB AGAINST A NUMBER OR A TEMPORAL COMPARES AS TEXT.
#
# The engine's blob comparison (CVT2_blob_compare) makes the OTHER operand
# a string - its CAST-to-text render - and compares strings, for a text
# blob and a binary one alike. Measured on 6.0.0.2196:
#
#   B = 3        '3' only - not '3.0' (a VARCHAR operand would convert the
#                text to the number and match both)
#   B = 3.0      '3.0' only;  B = 3e0  the DOUBLE render '3.000000000000000'
#   B > 9        '9x' and 'TRUE' - text order; '10' is LESS than '9'
#   B = DT       a DATE renders '2020-01-01'
#   LIST(ID) = 3 false for '1,2', true for '3' - no conversion error
#
# This server read the blob as a VARCHAR operand: every row above was
# another answer, and `LIST(ID) = 3` raised 22018. A BOOLEAN against a
# blob is the engine's 22018 on the string "BLOB" - this server raises on
# the content instead (recorded, section 9). A `?` beside a blob refuses
# at prepare here (not measured).
#
#   qa/serve-real-blobcmp.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4599}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/blobcmp-eng.fdb"; FC="$D/blobcmp-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE G (ID INTEGER, K VARCHAR(5), C CHAR(3));
INSERT INTO G VALUES (1, 'a', 'x');
INSERT INTO G VALUES (2, 'b', 'x');
INSERT INTO G VALUES (3, NULL, 'y');
CREATE TABLE BT (ID INTEGER, B BLOB SUB_TYPE TEXT, N VARCHAR(20), D DOUBLE PRECISION, DT DATE, BB BLOB SUB_TYPE BINARY, BO BOOLEAN, NM NUMERIC(5,1));
COMMIT;
INSERT INTO BT (ID, B, N) VALUES (3, '3', '3');
INSERT INTO BT (ID, B, N) VALUES (10, '10', '10');
INSERT INTO BT (ID, B, N) VALUES (2, '3.0', '3.0');
UPDATE BT SET D = ID, DT = DATE '2020-01-01', BB = B, BO = TRUE, NM = ID;
INSERT INTO BT (ID, B, N) VALUES (4, '2020-01-01', '2020-01-01');
INSERT INTO BT (ID, B, N) VALUES (5, 'TRUE', 'TRUE');
INSERT INTO BT (ID, B, N) VALUES (6, '9x', '9x');
INSERT INTO BT (ID, B, N) VALUES (7, '3.000000000000000', '3.000000000000000');
INSERT INTO BT (ID, B, N) VALUES (8, NULL, NULL);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/blobcmp-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/blobcmp-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-blobcmp-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# every cell prints a sentinel first, so a statement that answers NO ROWS
# (isql then prints nothing) is still a line both sides must agree on
run() { printf "SELECT 'cell' AS S FROM RDB\$DATABASE;\n%s\n" "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
both() { # <label> <sql>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "${e#*cell}" = "$e" ]; then echo "FAIL $1 [the engine never ran the cell: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
# the engine's answer, pinned: what the cell measures stays in the file
pin() { # <label> <sql> <expected ids, space separated>
    ran=$((ran + 1))
    local e c want
    want="$3"
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '|' '\n' | grep -E '^ *[0-9]+$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')
    c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '|' '\n' | grep -E '^ *[0-9]+$' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')
    if [ "$e" != "$want" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$want]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 a text blob against an exact number: the number's text"
pin  "1 B = 3: '3' and not '3.0'"            "SELECT ID FROM BT WHERE B = 3;" "3"
pin  "1 3 = B, the mirror"                    "SELECT ID FROM BT WHERE 3 = B;" "3"
pin  "1 B = 3.0: '3.0' only"                  "SELECT ID FROM BT WHERE B = 3.0;" "2"
pin  "1 B > 9: text order"                    "SELECT ID FROM BT WHERE B > 9;" "5 6"
pin  "1 B < ID, per row ('3.0..' < '7')"                   "SELECT ID FROM BT WHERE B < ID;" "4 7"
pin  "1 B = ID, per row"                      "SELECT ID FROM BT WHERE B = ID;" "3 10"
pin  "1 B = NM (NUMERIC(5,1) renders 3.0)"   "SELECT ID FROM BT WHERE B = NM;" ""
pin  "1 B IN (3, 10)"                         "SELECT ID FROM BT WHERE B IN (3, 10);" "3 10"
pin  "1 B BETWEEN 1 AND 5"                    "SELECT ID FROM BT WHERE B BETWEEN 1 AND 5;" "3 10 2 4 7"
pin  "1 a BIGINT, a DECFLOAT"                 "SELECT ID FROM BT WHERE B = CAST(3 AS BIGINT) OR B = CAST(10 AS DECFLOAT(16));" "3 10"
echo "--- 2 an approximate number: the DOUBLE's own render"
pin  "2 B = 3e0"                              "SELECT ID FROM BT WHERE B = 3e0;" "7"
pin  "2 B = D (a DOUBLE column)"              "SELECT ID FROM BT WHERE B = D;" ""
pin  "2 B = D + 0.5"                          "SELECT ID FROM BT WHERE B = D + 0.5;" ""
echo "--- 3 a temporal: its text"
pin  "3 B = DATE '2020-01-01'"                "SELECT ID FROM BT WHERE B = DATE '2020-01-01';" "4"
pin  "3 B = DT (a DATE column)"               "SELECT ID FROM BT WHERE B = DT;" ""
pin  "3 B = a TIMESTAMP"                      "SELECT ID FROM BT WHERE B = TIMESTAMP '2020-01-01 00:00:00';" ""
echo "--- 4 a binary blob, a blob expression"
pin  "4 BB = 3 (binary blob)"                 "SELECT ID FROM BT WHERE BB = 3;" "3"
pin  "4 CAST(B AS BLOB SUB_TYPE BINARY) = 3"  "SELECT ID FROM BT WHERE CAST(B AS BLOB SUB_TYPE BINARY) = 3;" "3"
pin  "4 UPPER(B) = 3"                         "SELECT ID FROM BT WHERE UPPER(B) = 3;" "3"
pin  "4 B || '' = 3"                          "SELECT ID FROM BT WHERE B || '' = 3;" "3"
echo "--- 5 in a projection, IIF, CASE"
both "5 B = 3 projected"                      "SELECT ID, B = 3 AS X FROM BT;"
both "5 BB = 3 projected (NULL rows)"         "SELECT ID, BB = 3 AS X FROM BT;"
both "5 IIF(B = 3, ..)"                       "SELECT ID, IIF(B = 3, 'y', 'n') AS X FROM BT;"
both "5 CASE WHEN B > 9"                      "SELECT ID, CASE WHEN B > 9 THEN 'y' ELSE 'n' END AS X FROM BT;"
echo "--- 6 a LIST against a number"
both "6 HAVING LIST(ID) = 3"                  "SELECT C FROM G GROUP BY C HAVING LIST(ID) = 3;"
both "6 HAVING 3 = LIST(ID)"                  "SELECT C FROM G GROUP BY C HAVING 3 = LIST(ID);"
both "6 HAVING LIST(ID) > 10"                 "SELECT C FROM G GROUP BY C HAVING LIST(ID) > 10;"
both "6 HAVING LIST(K) = 1 - no 22018"        "SELECT C FROM G GROUP BY C HAVING LIST(K) = 1;"
both "6 HAVING LIST(ID) = 3.0"                "SELECT C FROM G GROUP BY C HAVING LIST(ID) = 3.0;"
both "6 HAVING LIST(ID) = COUNT(*) / MAX(ID)" "SELECT C FROM G GROUP BY C HAVING LIST(ID) = COUNT(*) OR LIST(ID) = MAX(ID);"
both "6 LIST(ID) = 3 projected"               "SELECT C, LIST(ID) = 3 AS X FROM G GROUP BY C ORDER BY C;"
echo "--- 7 CONTROLS - a VARCHAR still converts its text to the number"
pin  "7 N = 3 matches '3', '3.0', '3.000..'"  "SELECT ID FROM BT WHERE ID IN (3, 10, 2, 7) AND N = 3;" "3 2 7"
pin  "7 N > 9 compares numbers"               "SELECT ID FROM BT WHERE ID IN (3, 10, 2, 7) AND N > 9;" "10"
# (the same 22018 on the first row that is not a number; the engine has
# delivered the rows before it, this server raises without them - the
# recorded "rows before a raise" of docs/roadmap.md, compared from the error)
ran=$((ran + 1))
e=$(run "127.0.0.1/$REAL:$ENG" "SELECT ID FROM BT WHERE N = 3;"); c=$(run "127.0.0.1/$PORT:$FC" "SELECT ID FROM BT WHERE N = 3;")
if [ "${e#*Statement failed}" != "$e" ] && [ "Statement failed${e#*Statement failed}" = "Statement failed${c#*Statement failed}" ]; then
    echo "OK   7 N = 3 over a non-number row: the same 22018"
else echo "DIFF 7 N = 3 over a non-number row"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
pin  "7 B = '3' - a text literal"             "SELECT ID FROM BT WHERE B = '3';" "3"
echo "--- 9 RECORDED - a BOOLEAN against a blob: both raise 22018, on another string"
ran=$((ran + 1))
e=$(run "127.0.0.1/$REAL:$ENG" "SELECT ID FROM BT WHERE B = TRUE;"); c=$(run "127.0.0.1/$PORT:$FC" "SELECT ID FROM BT WHERE B = TRUE;")
if [ "$e" = "$c" ]; then echo "FAIL 9 B = TRUE - IT AGREES NOW; promote the cell"; fail=1
elif [ "${e#*conversion error from string \"BLOB\"}" != "$e" ] && [ "${c#*SQLSTATE = 22018}" != "$c" ]; then
    echo "OK   9 B = TRUE (recorded: the engine's 22018 names \"BLOB\", this server's the content)"
else echo "FAIL 9 B = TRUE moved"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-blobcmp-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count
if [ "$ran" -lt 37 ]; then echo "FAIL only $ran checks ran (floor 37) - cells went missing"; fail=1; fi
exit $fail
