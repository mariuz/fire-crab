#!/bin/bash
# AN EXPRESSION OVER LIST: `CAST(LIST(K) AS VARCHAR(n))` - the reporting
# idiom that turns the aggregate's text BLOB into a string.
#
# Every expression over a LIST refused at prepare: the fold's slot had no
# descriptor ("a computed BLOB"), so nothing could be typed over it. The
# slot holds the minted blob exactly as a blob column's slot holds its id,
# so it is described as one now - a TEXT BLOB in the ARGUMENT's character
# set (the first text column it references; NONE for a literal, a number, a
# temporal - ListAggNode::make) - and a CAST over it reads it as a blob
# operand does. Measured on 2196: the plain, grouped, DISTINCT, HAVING and
# empty forms, the describe (VARYING n in the cast's set), and the 22001
# `expected length 2, actual 3` when the list does not fit.
#
# STILL REFUSED (section 2, recorded - each fails the day it answers):
# LIST(K) || '!', UPPER / SUBSTRING / COALESCE over it (blob-returning)
# and CHAR_LENGTH / OCTET_LENGTH - the select-list route that types those
# over a blob COLUMN is not the one the grouped path takes.
#
#   qa/serve-real-listexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4598}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/listexpr-eng.fdb"; FC="$D/listexpr-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE G (ID INTEGER, K VARCHAR(5), C CHAR(3), W VARCHAR(5) CHARACTER SET WIN1252);
INSERT INTO G VALUES (1, 'a', 'x', 'é');
INSERT INTO G VALUES (2, 'b', 'x', 'ü');
INSERT INTO G VALUES (3, NULL, 'y', NULL);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/listexpr-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/listexpr-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-listexpr-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
run() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 60 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 | norm; }
both() { # <label> <sql> - the describe and the answer
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$e" ]; then echo "FAIL $1 [the engine printed nothing]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
recorded() { # <label> <sql> - the engine answers, this server refuses at prepare
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "${e#*Statement failed}" != "$e" ]; then echo "FAIL $1 - the ENGINE no longer answers [$e]"; fail=1
    elif [ "${c#*Statement failed, SQLSTATE = 42000|Dynamic SQL Error|}" = "$c" ]; then
        echo "FAIL $1 - this server moved; promote if it matches"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1
    else echo "OK   $1 (recorded: the engine answers, this server refuses)"; fi
}

echo "--- 1 CAST over a LIST"
both "1 the whole table"                     "SELECT CAST(LIST(K) AS VARCHAR(50)) FROM G;"
both "1 per group, a separator, an alias"    "SELECT C, CAST(LIST(ID, '-') AS VARCHAR(20)) AS L FROM G GROUP BY C;"
both "1 too short: 22001 at the fetch"       "SELECT CAST(LIST(K) AS VARCHAR(2)) FROM G;"
both "1 DISTINCT over a CHAR - padded"       "SELECT CAST(LIST(DISTINCT C) AS VARCHAR(20)) FROM G;"
both "1 in HAVING"                           "SELECT C FROM G GROUP BY C HAVING CAST(LIST(ID) AS VARCHAR(10)) = '1,2';"
both "1 an empty set is NULL"                "SELECT CAST(LIST(K) AS VARCHAR(50)) FROM G WHERE 1 = 0;"
both "1 a WIN1252 argument, cast to UTF8"    "SELECT CAST(LIST(W) AS VARCHAR(20) CHARACTER SET UTF8) FROM G;"
both "1 a numeric argument"                  "SELECT CAST(LIST(ID * 10) AS VARCHAR(20)) FROM G;"
both "1 beside another aggregate"            "SELECT COUNT(*), CAST(LIST(K, '|') AS VARCHAR(20)) FROM G;"

echo "--- 2 RECORDED - the engine answers, this server refuses"
recorded "2 LIST(K) || '!'"                  "SELECT LIST(K) || '!' FROM G;"
recorded "2 UPPER(LIST(K))"                  "SELECT UPPER(LIST(K)) FROM G;"
recorded "2 CHAR_LENGTH(LIST(K))"            "SELECT CHAR_LENGTH(LIST(K)) FROM G;"
recorded "2 OCTET_LENGTH(LIST(K))"           "SELECT OCTET_LENGTH(LIST(K)) FROM G;"

echo "--- 3 CONTROLS - a bare LIST and a non-LIST cast"
both "3 a bare LIST is still its blob"       "SELECT CHAR_LENGTH(CAST(MAX(K) AS VARCHAR(5))) FROM G;"
both "3 a CAST over MAX"                     "SELECT CAST(MAX(ID) AS VARCHAR(5)) FROM G;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-listexpr-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 16 on the 2026-10-03 binary, 16 OK
if [ "$ran" -lt 16 ]; then echo "FAIL only $ran checks ran (floor 16) - cells went missing"; fail=1; fi
exit $fail
