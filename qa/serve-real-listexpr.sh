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
# EVERY OTHER EXPRESSION over it (section 2) since 2026-10-03, after three
# fixes: the slot descriptor carried offset 0, which reads as a COMPUTED BY
# column and refused every operand; the grouped select list stored the
# BARE expression, not the one wrapped to mint a blob result (a blob-out
# expression shipped as id 0:0, EMPTY at the client - a wrong answer); and
# a computed blob read by a LATER op of its statement (the fold runs at
# execute, the select list at the fetch) was looked for only in the mint.
# A LIST in HAVING's condition answers too (2b), compared AS TEXT against
# a number (the engine's blob compare - serve-real-blobcmp.sh).
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
CREATE TABLE BT (ID INTEGER, B BLOB SUB_TYPE TEXT CHARACTER SET NONE, BW BLOB SUB_TYPE TEXT CHARACTER SET WIN1252);
INSERT INTO BT VALUES (1, 'abc', 'é');
INSERT INTO BT VALUES (2, 'de', 'ü');
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
# (a blob id line - `0:1c`, the value column beside it - is the server's own
# numbering, not the content, which isql prints after it)
run() { printf 'SET SQLDA_DISPLAY ON;\nSET BLOB ALL;\n%s\n' "$2" | timeout 60 "$ISQL" -q -ch "${CH:-UTF8}" -user "$U" -pas "$P" "$1" 2>&1 \
    | sed -E 's/(^| +)[0-9a-f]+:[0-9a-f]+( |$)/\1\2/g; s/(^| +)[0-9a-f]+:[0-9a-f]+( |$)/\1\2/g; s/ +$//' | norm; }
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

echo "--- 2 every other expression over a LIST (recorded refusals until 2026-10-03)"
both "2 LIST(K) || '!' - a blob out"          "SELECT LIST(K) || '!' FROM G;"
both "2 UPPER(LIST(K))"                        "SELECT UPPER(LIST(K)) FROM G;"
both "2 CHAR_LENGTH(LIST(K))"                  "SELECT CHAR_LENGTH(LIST(K)) FROM G;"
both "2 OCTET_LENGTH(LIST(K))"                 "SELECT OCTET_LENGTH(LIST(K)) FROM G;"
both "2 SUBSTRING over a LIST"                 "SELECT SUBSTRING(LIST(K) FROM 1 FOR 2) FROM G;"
both "2 COALESCE over an empty LIST - a blob"  "SELECT COALESCE(LIST(K), 'none') FROM G WHERE 1 = 0;"
both "2 per group: lengths, a concatenation"   "SELECT C, CHAR_LENGTH(LIST(ID)) AS L, OCTET_LENGTH(LIST(ID)) AS O, LIST(ID) || '.' AS X FROM G GROUP BY C ORDER BY 1;"
both "2 a WIN1252 argument's octets"           "SELECT OCTET_LENGTH(LIST(W)), CHAR_LENGTH(LIST(W)) FROM G;"
both "2 IIF over a LIST"                       "SELECT IIF(LIST(K) = 'a,b', 1, 0) FROM G;"
both "2 CASE WHEN a LIST IS NULL"              "SELECT CASE WHEN LIST(K) IS NULL THEN 'n' ELSE 'y' END FROM G;"
both "2 ORDER BY a LIST"                       "SELECT C, COUNT(*) FROM G GROUP BY C ORDER BY LIST(ID);"
echo "--- 2b a LIST in HAVING's condition (recorded refusals until 2026-10-03: the keyed path compares integer folds only)"
both "2b HAVING LIST(..) = 'text'"         "SELECT C FROM G GROUP BY C HAVING LIST(ID) = '1,2';"
both "2b HAVING LIST(..) LIKE"             "SELECT C FROM G GROUP BY C HAVING LIST(ID) LIKE '1%';"
both "2b HAVING LIST(..) IS NULL"          "SELECT C FROM G GROUP BY C HAVING LIST(K) IS NULL;"
both "2b STARTING / CONTAINING / SIMILAR"  "SELECT C FROM G GROUP BY C HAVING LIST(ID) STARTING '1' OR LIST(ID) CONTAINING '3' OR LIST(ID) SIMILAR TO '9%';"
both "2b IN, BETWEEN, NOT, <>"             "SELECT C FROM G GROUP BY C HAVING LIST(ID) IN ('1,2', '7') AND LIST(ID) BETWEEN '0' AND '2' AND NOT LIST(ID, '-') <> '1-2';"
both "2b LIST(DISTINCT ..) = text, OR an integer fold" "SELECT C FROM G GROUP BY C HAVING LIST(DISTINCT C) = 'y' OR COUNT(*) = 2;"
both "2b against a NUMBER: text, no 22018" "SELECT C FROM G GROUP BY C HAVING LIST(ID) = 3;"
both "2b against a number, ordered as text" "SELECT C FROM G GROUP BY C HAVING LIST(ID) > 10;"
both "2b against MAX(ID)"                   "SELECT C FROM G GROUP BY C HAVING LIST(ID) = MAX(ID);"
both "2b a projected LIST(ID) = 3"          "SELECT C, LIST(ID) = 3 AS B FROM G GROUP BY C ORDER BY C;"

echo "--- 4 THE SETS: a computed blob's bytes, under UTF8, NONE and WIN1252 attachments"
# a LIST is minted in its argument's set and a blob-valued expression in
# its own, and each is delivered in the attachment's as a stored blob is:
# shipped raw, `UPPER(<a WIN1252 blob>)` reached a UTF8 client as an
# invalid byte, a bare LIST(<WIN1252>) a NONE one as UTF-8, and a NONE
# blob `|| '.'` was described NONE where the literal's set rules
for CH in UTF8 NONE WIN1252; do
  both "4 [$CH] a NONE blob || a literal"        "SELECT B || '.' FROM BT WHERE ID = 1;"
  both "4 [$CH] UPPER / || over a WIN1252 blob"  "SELECT UPPER(BW) AS U, BW || '.' AS C FROM BT WHERE ID = 1;"
  both "4 [$CH] a LIST of WIN1252 values"         "SELECT LIST(BW) AS L, LIST(W, '|') AS L2 FROM BT, G WHERE G.ID = BT.ID;"
  both "4 [$CH] lengths of WIN1252 lists"         "SELECT OCTET_LENGTH(LIST(W)) AS O, CHAR_LENGTH(LIST(W)) AS C FROM G;"
  both "4 [$CH] LIST(W) || '.', UPPER(LIST(W))"   "SELECT LIST(W) || '.' AS X, UPPER(LIST(W)) AS U FROM G;"
done
CH=UTF8

echo "--- 3 CONTROLS - a bare LIST and a non-LIST cast"
both "3 a bare LIST is still its blob"       "SELECT CHAR_LENGTH(CAST(MAX(K) AS VARCHAR(5))) FROM G;"
both "3 a CAST over MAX"                     "SELECT CAST(MAX(ID) AS VARCHAR(5)) FROM G;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-listexpr-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 48 on the 2026-10-03 binary, 48 OK
if [ "$ran" -lt 48 ]; then echo "FAIL only $ran checks ran (floor 48) - cells went missing"; fail=1; fi
exit $fail
