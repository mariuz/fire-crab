#!/bin/bash
# INSERT .. SELECT OF NON-ASCII TEXT INTO A UTF8 DATABASE, under every
# attachment set. The per-row INSERT spelled a selected UTF8 value as a
# plain literal, which re-parsed in the ATTACHMENT's set: under a NONE
# attachment `INSERT INTO P SELECT ID + 10, T || 'x' FROM P` over a 'Déf'
# row refused the statement (measured on 2196: the engine copies it). A
# GENUINE UTF8 source - a UTF8 column, or an expression typed UTF8 - now
# binds as a UTF8-tagged parameter; a literal in the attachment's set keeps
# the literal path (its value IS its bytes: a MERGE's NOT MATCHED 'éé'
# under NONE stores 4 bytes, not 8 - the control in section 2).
#
#   qa/serve-real-inselutf8.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4630}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/iu8-eng.fdb"; FC="$D/iu8-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE P (ID INT, T VARCHAR(20), N INT);
CREATE TABLE W (ID INT, T VARCHAR(20) CHARACTER SET WIN1252);
INSERT INTO P VALUES (2, 'Déf', 7);
INSERT INTO P VALUES (4, 'abc', -3);
INSERT INTO W VALUES (1, 'é');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/iu8-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/iu8-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-iu8-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "SELECT 'SENTINEL' AS S FROM RDB\$DATABASE;\n%s\n" "$3" \
    | timeout -s KILL 30 "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -a -v '^$' | sed -E 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() { # <label> <attachment set> <sql>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" "$3"); c=$(run "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ "${e#*SENTINEL}" = "$e" ]; then echo "FAIL $1 [the cell never ran: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [${e#*SENTINEL|}]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 a selected UTF8 value, copied and concatenated, under each attachment"
for att in NONE UTF8 WIN1252; do
    both "1 $att: a UTF8 column copied" "$att" "INSERT INTO P SELECT ID + 10, T, N FROM P WHERE ID = 2; SELECT ID, T, OCTET_LENGTH(T) FROM P ORDER BY ID; ROLLBACK;"
    both "1 $att: a UTF8 expression (T || 'x', UPPER)" "$att" "INSERT INTO P SELECT ID + 10, T || 'x', N + 1 FROM P; INSERT INTO P SELECT ID + 20, UPPER(T), N FROM P WHERE ID = 2; SELECT ID, T, OCTET_LENGTH(T), N FROM P ORDER BY ID; ROLLBACK;"
    both "1 $att: a WIN1252 column into a UTF8 one" "$att" "INSERT INTO P (ID, T) SELECT ID + 30, T FROM W; SELECT ID, T, OCTET_LENGTH(T) FROM P WHERE ID > 30; ROLLBACK;"
done

echo "--- 2 CONTROLS: a literal in the attachment's set keeps its bytes"
both "2 NONE: a MERGE NOT MATCHED literal 'éé' (4 bytes)" NONE "MERGE INTO P USING (SELECT 9 AS ID FROM RDB\$DATABASE) S ON P.ID = S.ID WHEN NOT MATCHED THEN INSERT (ID, T) VALUES (S.ID, 'éé'); SELECT ID, OCTET_LENGTH(T) FROM P ORDER BY ID; ROLLBACK;"
both "2 NONE: an INSERT .. SELECT of a literal" NONE "INSERT INTO P (ID, T) SELECT 9, 'é' FROM RDB\$DATABASE; SELECT ID, OCTET_LENGTH(T) FROM P ORDER BY ID; ROLLBACK;"
both "2 UTF8: the same literal" UTF8 "INSERT INTO P (ID, T) SELECT 9, 'é' FROM RDB\$DATABASE; SELECT ID, T, OCTET_LENGTH(T) FROM P ORDER BY ID; ROLLBACK;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-iu8-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 13 on the 2026-10-05 binary, 13 OK
if [ "$ran" -lt 13 ]; then echo "FAIL only $ran checks ran (floor 13) - cells went missing"; fail=1; fi
exit $fail
