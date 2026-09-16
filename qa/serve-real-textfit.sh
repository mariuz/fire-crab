#!/bin/bash
# A TEXT VALUE TOO LONG FOR ITS COLUMN RAISES THE ENGINE'S 22001 - on
# every write path, with the two counts the error carries.
#
# fire-crab answered a bare "Dynamic SQL Error" (SQLSTATE 42000) for all
# of them: encode_wire_value returns a plain None when the value does not
# fit, and each DML caller mapped that None to its own generic message,
# throwing away what the client needs to know. The engine raises
#
#     SQLSTATE 22001, string right truncation
#     -expected length 5, actual 7
#
# where `expected` is the column's declared CHARACTER count and `actual`
# the value's own, measured in the DESTINATION's characters - one byte is
# one character in a byte carrier, which is why five two-byte characters
# into a VARCHAR(5) CHARACTER SET NONE report 10 while seven of them into
# a VARCHAR(5) UTF8 report 7. Measured cell by cell on both sides.
#
# CHAR behaves exactly like VARCHAR HERE (CHAR(5) = 'abcdefg' is
# "expected 5, actual 7") - the blank padding is not counted, unlike the
# OUT-capacity rule where a CHAR counts its padding. A value that fits
# still pads silently.
#
# NOT every refusal is this one: a character with no image in the
# destination character set is a TRANSLITERATION failure and keeps its
# own vector, which is why the fit check reports WHY it failed rather
# than a bare None (see [TextFit]).
#
# Usage: qa/serve-real-textfit.sh [port]   (default 4181)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4181}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/textfit-eng.fdb"; FC="$D/textfit-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/textfit-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, SN VARCHAR(5), SU VARCHAR(5) CHARACTER SET UTF8,
                CN CHAR(5), CU CHAR(5) CHARACTER SET UTF8, SW VARCHAR(5) CHARACTER SET WIN1252);
INSERT INTO T SELECT ROW_NUMBER() OVER(), 'x', 'x', 'x', 'x', 'x' FROM RDB$RELATIONS ROWS 40;
CREATE TABLE SRC (ID INTEGER, S VARCHAR(20));
INSERT INTO SRC VALUES (1, 'abcdefg');
CREATE TABLE DFT (ID INTEGER, S VARCHAR(5) DEFAULT 'abcdefg');
CREATE TABLE DFOK (ID INTEGER, S VARCHAR(5) DEFAULT 'abc');
COMMIT;
SQL
if grep -qi error /tmp/textfit-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/textfit-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-textfit.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the STATUS LINES a statement answers, whole: the SQLSTATE and every
# secondary line, which is where `expected length N, actual M` lives -
# comparing only the SQLSTATE would have called a 42000-for-22001 a pass
status() { # <conn> <charset> <statement>
    printf '%s\n' "$3" \
        | "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "$1" 2>&1 \
        | grep -aE 'SQLSTATE|^-' | sed 's/^ *//;s/  */ /g' | tr '\n' '|'
}
stored() { # <conn> <charset> <query>
    printf 'SET LIST ON;\n%s\n' "$3" \
        | "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "$1" 2>&1 \
        | grep -aE '^[A-Z_]+ ' | sed 's/  */ /g' | tr '\n' '|'
}
cell() { # <label> <charset> <statement> [readback-query]
    local e f se sf
    e=$(status "127.0.0.1/3050:$ENG" "$2" "$3")
    f=$(status "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ -n "${4:-}" ]; then
        se=$(stored "127.0.0.1/3050:$ENG" "$2" "$4")
        sf=$(stored "127.0.0.1/$PORT:$FC" "$2" "$4")
    fi
    if [ "$e" = "$f" ] && [ "${se:-}" = "${sf:-}" ]; then
        echo "OK   $1 => ${e:-(ok)} ${se:-}"
    else
        echo "DIFF $1"
        echo "     eng: ${e:-(ok)} ${se:-}"
        echo "     fc : ${f:-(ok)} ${sf:-}"
        fail=1
    fi
}

echo "-- the 22001 and its counts, on every write path --"
cell "UPDATE literal over-long"       NONE "UPDATE T SET SN = 'abcdefg' WHERE ID = 1;"                       "SELECT SN FROM T WHERE ID = 1;"
cell "INSERT literal over-long"       NONE "INSERT INTO T (ID, SN) VALUES (101, 'abcdefg');"                 "SELECT COUNT(*) C FROM T WHERE ID = 101;"
cell "INSERT .. SELECT over-long"     NONE "INSERT INTO T (ID, SN) SELECT 102, S FROM SRC WHERE ID = 1;"     "SELECT COUNT(*) C FROM T WHERE ID = 102;"
cell "UPDATE .. RETURNING over-long"  NONE "UPDATE T SET SN = 'abcdefg' WHERE ID = 2 RETURNING SN;"          "SELECT SN FROM T WHERE ID = 2;"
cell "MERGE over-long"                NONE "MERGE INTO T USING (SELECT 3 AS K FROM RDB\$DATABASE) S ON T.ID = S.K WHEN MATCHED THEN UPDATE SET SN = 'abcdefg';" "SELECT SN FROM T WHERE ID = 3;"
cell "concat over-long (actual 8)"    NONE "UPDATE T SET SN = SN || 'abcdefg' WHERE ID = 4;"                 "SELECT SN FROM T WHERE ID = 4;"

echo "-- the counts are DESTINATION characters: bytes in a carrier, characters in a real set --"
cell "VARCHAR(5) NONE, 5 two-byte (actual 10)" UTF8 "UPDATE T SET SN = 'ééééé' WHERE ID = 5;"              "SELECT CHAR_LENGTH(SN) L FROM T WHERE ID = 5;"
cell "VARCHAR(5) UTF8, 7 two-byte (actual 7)"  UTF8 "UPDATE T SET SU = 'ééééééé' WHERE ID = 6;"          "SELECT CHAR_LENGTH(SU) L FROM T WHERE ID = 6;"
cell "VARCHAR(5) UTF8, 7 ascii (actual 7)"     UTF8 "UPDATE T SET SU = 'abcdefg' WHERE ID = 7;"              "SELECT CHAR_LENGTH(SU) L FROM T WHERE ID = 7;"

echo "-- CHAR takes the same rule, and its padding is NOT counted --"
cell "CHAR(5) NONE over-long"         NONE "UPDATE T SET CN = 'abcdefg' WHERE ID = 8;"                       "SELECT CN FROM T WHERE ID = 8;"
cell "CHAR(5) UTF8 over-long"         UTF8 "UPDATE T SET CU = 'ééééééé' WHERE ID = 9;"                    "SELECT CHAR_LENGTH(CU) L FROM T WHERE ID = 9;"
cell "CHAR(5) NONE, 2-byte (actual 10)" UTF8 "UPDATE T SET CN = 'ééééé' WHERE ID = 10;"                   "SELECT CHAR_LENGTH(CN) L FROM T WHERE ID = 10;"

echo "-- and a value that FITS still lands (the controls that keep the fix honest) --"
cell "CHAR(5) fits, pads silently"    NONE "UPDATE T SET CN = 'abc' WHERE ID = 11;"                          "SELECT CN, CHAR_LENGTH(CN) L FROM T WHERE ID = 11;"
cell "VARCHAR(5) exact fit"           NONE "UPDATE T SET SN = 'abcde' WHERE ID = 12;"                        "SELECT SN FROM T WHERE ID = 12;"
cell "VARCHAR(5) UTF8 exact fit"      UTF8 "UPDATE T SET SU = 'ééééé' WHERE ID = 13;"                     "SELECT CHAR_LENGTH(SU) L FROM T WHERE ID = 13;"
cell "NULL is not a truncation"       NONE "UPDATE T SET SN = NULL WHERE ID = 14;"                           "SELECT COALESCE(SN, 'nil') V FROM T WHERE ID = 14;"
cell "INSERT that fits"               NONE "INSERT INTO T (ID, SN) VALUES (103, 'abcde');"                   "SELECT SN FROM T WHERE ID = 103;"

echo "-- a column DEFAULT too long for its OWN column takes the same vector --"
cell "DEFAULT over-long, INSERT omits it" NONE "INSERT INTO DFT (ID) VALUES (1);"  "SELECT COUNT(*) C FROM DFT WHERE ID = 1;"
cell "DEFAULT that fits (control)"        NONE "INSERT INTO DFOK (ID) VALUES (1);" "SELECT S FROM DFOK WHERE ID = 1;"

# THE BOUND-? PATH IS NODE'S: isql cannot bind one, and node-firebird
# sends value-derived BLR whatever the describe announced - which is
# exactly the case the EXECUTE-side fit check has to answer, and a
# different code path from the literals above (those fail at PLAN).
# Defined HERE, before its call sites: a helper defined after them is
# not a helper at all, which this suite has already been bitten by.
HAVE_NODE=0
if command -v node >/dev/null 2>&1 && node -e 'require("node-firebird")' 2>/dev/null; then
    HAVE_NODE=1
fi
nrun() { # <port> <db> <sql> <json>
    FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2)=>{
          console.log(e2?("ERR "+String(e2.message||e2).replace(/\n/g," | ").trim()):"(ok)");
          db.detach();process.exit(0);});});' 2>/dev/null
}
bound() { # <label> <sql> <json>
    if [ $HAVE_NODE -ne 1 ]; then echo "SKIP $1 (node-firebird not resolvable)"; return; fi
    local e f
    e=$(nrun 3050 "$ENG" "$2" "$3"); f=$(nrun "$PORT" "$FC" "$2" "$3")
    if [ "$e" = "$f" ]; then echo "OK   $1 => $e"
    else echo "DIFF $1"; echo "     eng: $e"; echo "     fc : $f"; fail=1; fi
}
echo "-- and a BOUND ? too long for its column, the execute-side twin --"
bound "bound ? over-long (UPDATE)" "UPDATE T SET SN = ? WHERE ID = 20"     '["abcdefg"]'
bound "bound ? over-long (INSERT)" "INSERT INTO T (ID, SN) VALUES (201, ?)" '["abcdefg"]'
bound "bound ? 2-byte into NONE"   "UPDATE T SET SN = ? WHERE ID = 21"     '["ééééé"]'
bound "bound ? that fits"          "UPDATE T SET SN = ? WHERE ID = 22"     '["abcde"]'
bound "bound ? NULL"               "UPDATE T SET SN = ? WHERE ID = 23"     '[null]'

[ $fail -eq 0 ] && echo "PASS serve-real-textfit" || { echo "FAIL serve-real-textfit"; exit 1; }
