#!/bin/bash
# BLOB_APPEND(a, b, ..) - refused here until 2026-10-04 (found running the
# paper's samples/nodejs/blobs.js).
#
# Measured on 6.0.0.2196: the arguments' text appended in order, a NULL
# argument SKIPPED, NULL only when every argument is (at run time too);
# a BLOB whose subtype and set the FIRST argument decides - a text blob
# keeps its set, a binary blob gives subtype 0, a string literal or a NULL
# gives text in NONE, a number ASCII, a text column its own set; named
# BLOB_APPEND; one argument is a 39000 count error.
#
# Served as a CAST to that blob over `||` of the arguments (a literal as
# written, every other one COALESCEd to '' - the concatenation's own
# character-set law - and NULL when all of them are). RECORDED: the
# engine describes the column NOT NULL (520) and still delivers NULL
# through it; described Nullable here so the NULL travels (section 3,
# the describe compared without that flag); and non-ASCII text into a
# NONE blob counts double here (`OCTET_LENGTH` 11 for 7) - a CAST to a
# NONE text blob does the same, pre-existing.
#
#   qa/serve-real-blobappend.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4607}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/blobappend-eng.fdb"; FC="$D/blobappend-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE D (ID INTEGER, B BLOB SUB_TYPE TEXT, BB BLOB SUB_TYPE BINARY, V VARCHAR(10), N INTEGER,
  W VARCHAR(10) CHARACTER SET WIN1252, BN BLOB SUB_TYPE TEXT CHARACTER SET NONE);
INSERT INTO D VALUES (1, 'abc', 'xy', 'v1', 5, 'w', 'nn');
INSERT INTO D VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/blobappend-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/blobappend-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-blobappend-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
# (a blob id is each server's own numbering; the Nullable flag is section 3's)
norm() { grep -a -v '^$' | grep -v '^PLAN' | sed -E 's/  */ /g; s/ [0-9a-f]+:[0-9a-f]+$/ BLOBID/; s/ Nullable / /; s/ *$//' | tr '\n' '|'; }
run() { printf 'SET LIST ON;\nSET BLOB ALL;\n%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
both() { # <label> <sql>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$e" ]; then echo "FAIL $1 [the engine printed nothing]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 the value: NULLs skipped, NULL only when all are"
both "1 a blob, a literal, a column, per row"   "SELECT ID, BLOB_APPEND(B, '-', V) AS A FROM D ORDER BY ID;"
both "1 NULL first, numbers rendered"            "SELECT BLOB_APPEND(NULL, 'x', 1, 2.5) AS A FROM RDB\$DATABASE;"
both "1 two literals"                            "SELECT BLOB_APPEND('a', 'b') AS A FROM RDB\$DATABASE;"
both "1 every argument a NULL literal"           "SELECT BLOB_APPEND(NULL, NULL) AS A FROM RDB\$DATABASE;"
both "1 a binary blob first"                     "SELECT BLOB_APPEND(BB, 'z') AS A FROM D WHERE ID = 1;"
both "1 a NULL in the middle"                    "SELECT ID, BLOB_APPEND(B, NULL, 'q') AS A FROM D ORDER BY ID;"
both "1 all NULL at run time is NULL"            "SELECT BLOB_APPEND(B, V) AS R1, BLOB_APPEND(V, N) AS R2, BLOB_APPEND(B, V) IS NULL AS R3, OCTET_LENGTH(BLOB_APPEND(B, V)) AS R4 FROM D WHERE ID = 2;"
both "1 non-ASCII into a UTF8 blob: characters"  "SELECT CHAR_LENGTH(BLOB_APPEND(B, 'éé')) AS L FROM D WHERE ID = 1;"
both "1 a WIN1252 column first"                  "SELECT BLOB_APPEND(W, 'x', N) AS A FROM D WHERE ID = 1;"
both "1 stored by INSERT, by UPDATE"             "INSERT INTO D (ID, B) VALUES (3, BLOB_APPEND(CAST('' AS BLOB SUB_TYPE TEXT), 'p1-', 'p2')); UPDATE D SET B = BLOB_APPEND(B, '!') WHERE ID = 1; SELECT ID, B FROM D WHERE ID IN (1, 3) ORDER BY ID; ROLLBACK;"
both "1 in a WHERE"                              "SELECT ID FROM D WHERE BLOB_APPEND(B, '!') = 'abc!';"
echo "--- 2 the describe (without the Nullable flag - section 3)"
for a in "B, 'x'" "BB, 'x'" "'a', 'b'" "NULL, 'b'" "V, 1" "W, 'x'" "BN, 'x'" "1, 2" "NULL, NULL"; do
  both "2 BLOB_APPEND($a)" "SET SQLDA_DISPLAY ON; SET PLANONLY ON; SELECT BLOB_APPEND($a) FROM D;"
done
echo "--- 3 RECORDED"
ran=$((ran + 1))
raw() { printf 'SET SQLDA_DISPLAY ON;\nSET PLANONLY ON;\n%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep sqltype | sed 's/  */ /g'; }
e=$(raw "127.0.0.1/$REAL:$ENG" "SELECT BLOB_APPEND(B, 'x') FROM D;"); c=$(raw "127.0.0.1/$PORT:$FC" "SELECT BLOB_APPEND(B, 'x') FROM D;")
if [ "$e" = "$c" ]; then echo "FAIL 3 the describe's NOT NULL - IT AGREES NOW; promote"; fail=1
elif [ "${e#*Nullable}" = "$e" ] && [ "${c#*Nullable}" != "$c" ]; then echo "OK   3 the engine describes NOT NULL, this server Nullable (recorded)"
else echo "FAIL 3 the describe moved"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
ran=$((ran + 1))
e=$(run "127.0.0.1/$REAL:$ENG" "SELECT OCTET_LENGTH(BLOB_APPEND('abc', 'éé')) AS O FROM RDB\$DATABASE;"); c=$(run "127.0.0.1/$PORT:$FC" "SELECT OCTET_LENGTH(BLOB_APPEND('abc', 'éé')) AS O FROM RDB\$DATABASE;")
if [ "$e" = "$c" ]; then echo "FAIL 3 non-ASCII into NONE - IT AGREES NOW; promote"; fail=1
elif [ "$e" = "O 7|" ] && [ "$c" = "O 11|" ]; then echo "OK   3 non-ASCII into a NONE blob: 7 bytes on the engine, 11 here (recorded, the CAST's own)"
else echo "FAIL 3 non-ASCII into NONE moved"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-blobappend-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 23 ]; then echo "FAIL only $ran checks ran (floor 23) - cells went missing"; fail=1; fi
exit $fail
