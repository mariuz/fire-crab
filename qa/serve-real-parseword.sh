#!/bin/bash
# TWO REFUSALS OF THE GRAMMAR ITSELF, found running the paper's
# samples/nodejs/parser_errors.js: the parser's -104 Token unknown at the
# word, where this server answered a bare Dynamic SQL Error.
#
#   * a statement whose FIRST WORD starts no statement - `SELEC 1 FROM
#     RDB$DATABASE` is `Token unknown - line 1, column 1 / SELEC`;
#   * a WHERE with no condition before the next clause - `.. WHERE ORDER
#     BY 1` names ORDER at its own line and column.
#
#   qa/serve-real-parseword.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4605}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/parseword-eng.fdb"; FC="$D/parseword-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INTEGER, N INTEGER);
INSERT INTO T VALUES (1, 2);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/parseword-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/parseword-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-parseword-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | grep -v '^After line\|^At line' | tr '\n' '|'; }
both() { # <label> <sql>
    ran=$((ran + 1))
    local e c
    e=$(printf '%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ -z "$e" ]; then echo "FAIL $1 [the engine printed nothing]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 a first word that starts no statement"
both "1 SELEC"                                "SELEC 1 FROM RDB\$DATABASE;"
both "1 a lower-case one, after blanks"       "   selct id from t;"
both "1 a word on the second line"            $'\nFOO BAR;'
echo "--- 2 WHERE with no condition"
both "2 WHERE ORDER BY, three lines"          $'SELECT ID\nFROM T\nWHERE ORDER BY 1;'
both "2 WHERE GROUP BY"                       "SELECT N, COUNT(*) FROM T WHERE GROUP BY N;"
echo "--- 3 CONTROLS - statements that start right"
both "3 select, lower case"                   "select id from t where id = 1 order by 1;"
both "3 WITH"                                 "WITH X AS (SELECT ID FROM T) SELECT ID FROM X;"
both "3 a column named like a clause word is fine" "SELECT ID AS ROWS_N FROM T WHERE ID = 1;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-parseword-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 9 ]; then echo "FAIL only $ran checks ran (floor 9) - cells went missing"; fail=1; fi
exit $fail
