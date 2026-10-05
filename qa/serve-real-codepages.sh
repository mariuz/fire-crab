#!/bin/bash
# THE ENGINE'S SINGLE-BYTE CHARACTER SETS, TABLED. Only five were (ISO8859_1,
# WIN1252, ISO8859_2, WIN1250, WIN1251); a column of any other - DOS437,
# WIN1253, KOI8R, TIS620, ... - stored a non-ASCII value's UTF-8 BYTES, so
# the engine read back other characters and ordered the rows differently,
# and an index over it misled the engine (refused since 5995bf9). The 34
# tables ods::intl now carries were READ OFF THE LIVE ENGINE (6.0.0.2196):
# every byte 0x80..0xFF of every single-byte set decoded to UTF8 - a byte
# the codepage leaves undefined decodes to U+0000, the engine's own answer,
# and decoding never raises - and UPPER / LOWER of each byte read back in
# the set, a case mapping that leaves the set being the engine's 22018.
# A codepage HOLE keeps its C1 point in every table (the engine's U+0000 is
# recorded in section 3).
#
# The extraction, kept here so the tables can be regenerated: an EXECUTE
# BLOCK over RDB$CHARACTER_SETS (RDB$BYTES_PER_CHARACTER = 1), each byte as
# CAST(CAST(ASCII_CHAR(b) AS VARCHAR(1) CHARACTER SET OCTETS) AS VARCHAR(1)
# CHARACTER SET <set>), HEX_ENCODE'd after a CAST to UTF8, and after UPPER /
# LOWER and a CAST to OCTETS - each under its own WHEN ANY.
#
#   qa/serve-real-codepages.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4637}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/cpg-eng-$PORT.fdb"; FC="$D/cpg-fc-$PORT.fdb"; VFY="$D/cpg-vfy-$PORT.fdb"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INT, D437 VARCHAR(8) CHARACTER SET DOS437, D866 VARCHAR(8) CHARACTER SET DOS866,
  W53 VARCHAR(8) CHARACTER SET WIN1253, W55 VARCHAR(8) CHARACTER SET WIN1255, K8 VARCHAR(8) CHARACTER SET KOI8R,
  I7 VARCHAR(8) CHARACTER SET ISO8859_7, I9 VARCHAR(8) CHARACTER SET ISO8859_9, TH VARCHAR(8) CHARACTER SET TIS620,
  C850 CHAR(4) CHARACTER SET DOS850);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b -ch UTF8 > /tmp/cpg-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/cpg-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-cpg-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -ch "${3:-UTF8}" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ -z "$2" ]; then echo "FAIL $1 [the engine answered nothing]"; fail=1
    elif [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}
both() { check "$1" "$(run "127.0.0.1/$REAL:$ENG" "$2" "${3:-UTF8}")" "$(run "127.0.0.1/$PORT:$FC" "$2" "${3:-UTF8}")"; }

W="INSERT INTO T VALUES (1, 'Çüé', 'Жук', 'Αβγ', 'שלום', 'Мир', 'Ωμέγα', 'İşĞ', 'ไทย', 'Ñá');
INSERT INTO T VALUES (2, 'äÄ', 'жУК', 'αΒΓ', 'abc', 'мИР', 'ωΜ', 'işğ', 'กข', 'ñÁ');
INSERT INTO T VALUES (3, 'abc', 'abc', 'abc', NULL, 'abc', 'abc', 'abc', 'abc', 'ab');
INSERT INTO T VALUES (4, '½°', 'Ё', 'Ά', 'א', 'Ё', 'Ή', 'Ş', '฿', '£');
COMMIT;"
echo "--- 1 values in, values out, under a UTF8 attachment"
both "1 four rows across nine sets" "$W"
both "1 the values read back" "SELECT * FROM T ORDER BY ID;"
both "1 the STORED BYTES" "SELECT ID, HEX_ENCODE(CAST(D437 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(D866 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(W53 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(W55 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(K8 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(I7 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(I9 AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(TH AS VARCHAR(8) CHARACTER SET OCTETS)), HEX_ENCODE(CAST(C850 AS CHAR(4) CHARACTER SET OCTETS)) FROM T ORDER BY ID;"
both "1 OCTET_LENGTH / CHAR_LENGTH" "SELECT ID, OCTET_LENGTH(D437), CHAR_LENGTH(D866), OCTET_LENGTH(W55), OCTET_LENGTH(TH), OCTET_LENGTH(C850) FROM T ORDER BY ID;"

echo "--- 2 the set's own case law and order"
both "2 UPPER / LOWER per set" "SELECT ID, UPPER(D437), LOWER(D866), UPPER(W53), UPPER(K8), LOWER(I7), UPPER(I9), LOWER(I9) FROM T ORDER BY ID;"
both "2 equality and LIKE" "SELECT ID FROM T WHERE D866 = 'Жук'; SELECT ID FROM T WHERE W53 LIKE 'Α%'; SELECT ID FROM T WHERE TH STARTING WITH 'ไ';"
# RECORDED: an ORDER BY and a RANGE comparison over a single-byte set
# follow the set's BYTE order on the engine, Unicode order here - the same
# for every tabled set, WIN125x included where the two orders part
rec() { # <label> <sql> <engine> <this server>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '\n' '|'); c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}
# ORDER BY follows the set's CODEPAGE bytes, not the Unicode order of the
# decoded text (promoted 2026-10-05: DOS866 'Ё' is F0, last; WIN1252 '€'
# is 80, before every Latin-1 letter)
both "2 ORDER BY each set's byte order" "SELECT ID FROM T ORDER BY D437, ID; SELECT ID FROM T ORDER BY K8, ID; SELECT ID FROM T ORDER BY W53, ID; SELECT ID FROM T ORDER BY TH, ID; SELECT ID FROM T ORDER BY D866 DESC, ID; SELECT ID FROM T ORDER BY I7, W55, ID;"
both "2 ... through GROUP BY, DISTINCT and UNION" "SELECT K8, COUNT(*) FROM T GROUP BY K8 ORDER BY K8; SELECT DISTINCT D437 FROM T ORDER BY 1; SELECT K8 FROM T UNION SELECT D866 FROM T ORDER BY 1;"
both "2 the older tabled sets where the orders part (WIN1252 €, WIN1250, WIN1251)" "CREATE TABLE OW (ID INT, W2 VARCHAR(4) CHARACTER SET WIN1252, W0 VARCHAR(4) CHARACTER SET WIN1250, W1 VARCHAR(4) CHARACTER SET WIN1251); COMMIT; INSERT INTO OW VALUES (1, '€', 'Š', 'Ё'); INSERT INTO OW VALUES (2, 'a', 'Ź', 'Я'); INSERT INTO OW VALUES (3, 'é', 'ą', 'а'); INSERT INTO OW VALUES (4, 'Ÿ', 'z', 'ђ'); SELECT ID FROM OW ORDER BY W2, ID; SELECT ID FROM OW ORDER BY W0, ID; SELECT ID FROM OW ORDER BY W1, ID; ROLLBACK;"
# a RANGE compares the set's bytes too (promoted 2026-10-05: a KOI8R
# column against 'М' - the column's set decides, a literal adopts it)
both "2 ranges, BETWEEN, IN, MIN / MAX, CASE over a single-byte column" "SELECT ID FROM T WHERE K8 > 'М' ORDER BY ID; SELECT ID FROM T WHERE D866 BETWEEN 'А' AND 'я' ORDER BY ID; SELECT ID FROM T WHERE W53 IN ('Αβγ', 'abc') ORDER BY ID; SELECT MIN(D437), MAX(D437), MIN(K8), MAX(TH) FROM T; SELECT ID, CASE WHEN K8 < 'а' THEN 'lo' ELSE 'hi' END FROM T ORDER BY ID;"

both "2 the other routers: a grouped MIN, a window, an ORDER BY expression, a LEFT JOIN key" "SELECT ID / 3, MIN(K8), MAX(D866) FROM T GROUP BY 1 ORDER BY 1; SELECT ID, ROW_NUMBER() OVER (ORDER BY K8, ID) FROM T ORDER BY ID; SELECT ID FROM T ORDER BY UPPER(D437), ID; SELECT ID FROM T ORDER BY K8 || '', ID; SELECT A.ID, B.ID FROM T A LEFT JOIN T B ON A.K8 < B.K8 AND B.ID = 2 ORDER BY 1, 2;"

both "2 against a UTF8 side the COLUMN's bytes decide (a CAST, an _UTF8 literal, a UTF8 column)" "ALTER TABLE T ADD UU VARCHAR(8); COMMIT; UPDATE T SET UU = 'М'; SELECT ID FROM T WHERE K8 > UU ORDER BY ID; SELECT ID FROM T WHERE UU < K8 ORDER BY ID; SELECT ID FROM T WHERE K8 > CAST('М' AS VARCHAR(4) CHARACTER SET UTF8) ORDER BY ID; SELECT ID FROM T WHERE K8 > _UTF8 'М' ORDER BY ID; ROLLBACK;"
# ...but a BOUND `?` compares in UNICODE order (measured: 'мИР' > 'М')
if command -v node >/dev/null 2>&1 && node -e 'require("node-firebird")' 2>/dev/null; then
    nq() { FC_PORT="$1" FC_DB="$2" timeout 30 node -e '
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey",encoding:"UTF8"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query("SELECT ID FROM T WHERE K8 > ? ORDER BY ID",["М"],(e2,r)=>{console.log(e2?("ERR "+e2.message):JSON.stringify(r));db.detach();process.exit(0);});
      });' 2>/dev/null; }
    e=$(nq "$REAL" "$ENG"); c=$(nq "$PORT" "$FC")
    if [ -z "$e" ] || [ "$e" = CONN_ERR ]; then ran=$((ran + 1)); echo "FAIL 2 the bound cell never ran"; fail=1
    else check "2 a bound ? against a KOI8R column: Unicode order [$e]" "$e" "$c"; fi
else
    echo "SKIP 2 bound ?: node-firebird not resolvable"
fi

echo "--- 3 what the set cannot hold, and the other attachments"
rec "3 RECORDED a character outside the set: the engine's 22018 at execute, a refusal at prepare here (every tabled set)" \
    "INSERT INTO T (ID, K8) VALUES (9, 'Ω'); ROLLBACK;" 'Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets|X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|X|======|DONE|'
both "3 CAST into a set: the bytes, its case law, its 22018" "SELECT CAST('Çü' AS VARCHAR(3) CHARACTER SET DOS437) A, OCTET_LENGTH(CAST('Çü' AS VARCHAR(3) CHARACTER SET DOS437)) B, HEX_ENCODE(CAST(CAST('Жук' AS VARCHAR(3) CHARACTER SET KOI8R) AS VARCHAR(3) CHARACTER SET OCTETS)) C, UPPER(CAST('жук' AS VARCHAR(3) CHARACTER SET DOS866)) D FROM RDB\$DATABASE; SELECT CAST('Ω' AS VARCHAR(3) CHARACTER SET KOI8R) FROM RDB\$DATABASE;"
both "3 a comparison against a character outside the set raises 22018 (=, >, IN, <>)" "SELECT COUNT(*) FROM T WHERE K8 = 'Ω'; SELECT COUNT(*) FROM T WHERE K8 > 'Ω'; SELECT COUNT(*) FROM T WHERE K8 IN ('Ω', 'Мир'); SELECT COUNT(*) FROM T WHERE K8 <> 'Ω';"
rec "3 RECORDED a codepage HOLE: the engine transliterates it to U+0000 and refuses U+0081, this server keeps it at its C1 point (the tables stay bijections for byte-carrier delivery)" \
    "SELECT HEX_ENCODE(CAST(CAST(CAST(ASCII_CHAR(129) AS VARCHAR(1) CHARACTER SET OCTETS) AS VARCHAR(1) CHARACTER SET WIN1252) AS VARCHAR(2) CHARACTER SET UTF8)) A FROM RDB\$DATABASE;" \
    'A|================|00|X|======|DONE|' 'A|================|C281|X|======|DONE|'
both "3 the same rows under a WIN1251 attachment" "SELECT ID, D866, K8 FROM T ORDER BY ID;" WIN1251
both "3 ... and under NONE (the stored bytes)" "SELECT ID, D437 FROM T WHERE ID = 3;" NONE

echo "--- 4 an index over each kind, read by the ENGINE"
X="CREATE INDEX X_437 ON T (D437); CREATE INDEX X_K8 ON T (K8); CREATE DESCENDING INDEX X_TH ON T (TH); COMMIT;
INSERT INTO T (ID, D437, K8, TH) VALUES (5, 'Ü', 'Я', 'ก'); COMMIT;"
both "4 three indexes, then a write" "$X"
cp "$FC" "$VFY"; chmod 666 "$VFY"
Q="SET PLAN ON; SELECT ID FROM T WHERE D437 >= 'Ç' ORDER BY D437, ID; SELECT ID FROM T WHERE K8 = 'Мир'; SELECT ID FROM T ORDER BY TH DESC, ID;"
check "4 the engine's reads through them" "$(run "127.0.0.1/$REAL:$ENG" "$Q")" "$(run "127.0.0.1/$REAL:$VFY" "$Q")"
ran=$((ran + 1))
if "$GFIX" -v -full -user "$U" -pas "$P" "127.0.0.1/$REAL:$VFY" > /tmp/cpg-gfix.log 2>&1 && [ ! -s /tmp/cpg-gfix.log ]; then
    echo "OK   4 gfix -v -full finds it clean"
else echo "DIFF 4 gfix -v -full:"; sed 's/^/     /' /tmp/cpg-gfix.log | head; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-cpg-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 23 on the 2026-10-05 binary, 23 OK
if [ "$ran" -lt 23 ]; then echo "FAIL only $ran checks ran (floor 23) - cells went missing"; fail=1; fi
exit $fail
