#!/bin/bash
# DDL A SESSION JUST MADE, SEEN BY THE STATEMENTS AFTER IT.
#
# isql's AUTODDL runs each DDL statement in a transaction of its own and
# commits it, while the statements after it run in the SNAPSHOT
# transaction isql opened before the DDL. The engine resolves names
# through its metadata cache, which a committed DDL updates at once: the
# new object is usable in that older snapshot (while a user SELECT of
# RDB$PROCEDURES there still honours the snapshot and does not see its
# row). This server's own catalog walks - a table's defaults, a GTT's
# kind, a procedure's body, a trigger's list - read under the
# transaction's snapshot and answered what its START knew:
#
#   * `create procedure p0 ...^ select * from p0^` - a bare 42000
#     (functions, exceptions, packages the same) until a COMMIT;
#   * `create global temporary table ... on commit delete rows; commit;
#     insert; commit; select count(*)` - 1, not 0: the COMMIT purge's
#     list of GTTs was read under the old snapshot, found none, and that
#     empty answer was then held in the SHARED metadata cache until the
#     next DDL.
#
# Two write-side gaps, on the same probes:
#
#   * a column of a TEXT DOMAIN took RDB$FIELD_SUB_TYPE (0 for text) as
#     its descriptor sub_type, so its CHARACTER SET and COLLATE were
#     lost: `varchar(5) character set utf8 collate unicode_ci` described
#     charset 0 NONE and `where a = 'abc'` missed 'AbC' (engine: 1 row);
#   * ALTER TABLE ADD parsed a column's DEFAULT and never stored it: the
#     next INSERT read NULL where the engine reads the default.
#
# The second pass, on a review of the first (sections 5-17):
#
#   * ALTER TABLE ADD took the id a DROPPED field had, so the records
#     stored with that field read its bytes back under the new column;
#   * a TIME DEFAULT CURRENT_TIME stored milliseconds (precision 0 on
#     the engine), CURRENT_TIME(p) / CURRENT_TIMESTAMP(p), wide / exponent
#     / boolean literal defaults, a text BLOB default, ADD ... NOT NULL
#     and ADD ... IDENTITY were refused - or the identity read NULL;
#   * a UNICODE_CI column compared BYTE-WISE in CASE / IIF / IN / DECODE
#     / NULLIF / IS DISTINCT, while WHERE compared by the collation;
#   * 'é' from a NONE connection counted two characters into UTF8;
#   * a ROLLBACK of DDL left the cached plan of the rolled-back schema;
#   * ALTER SEQUENCE ... INCREMENT and a bare RESTART were refused;
#   * a column a trigger / view / procedure reads could be dropped;
#   * a key over a CI column was a BYTE index (it stored 'abc' beside
#     'AbC' under a PRIMARY KEY) - refused now.
# Section 17 stops the server and lets the ENGINE read this server's
# file: the format default sections and the default BLR it wrote.
#
# Usage: qa/serve-real-ddlmeta.sh [port]   (default 5440)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5440}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/ddlmeta-eng.fdb"; FC="$D/ddlmeta-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE TDUMMY (ID INTEGER);
CREATE TABLE TOLD (A INTEGER);
INSERT INTO TOLD VALUES (1);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/ddlmeta-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/ddlmeta-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/ddlmeta-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-ddlmeta-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session, isql's AUTODDL on), its lines squeezed and joined;
# errors included, so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# the engine is pinned and this server answers something ELSE - recorded,
# not fixed here; the cell fails once they agree (promote it)
recorded() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THEY NOW AGREE; promote the cell"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:90}], this server [${fv:0:90}])"; fi
}
DUAL='FROM RDB$DATABASE'

echo "--- 1. A GTT ON COMMIT DELETE ROWS MADE IN THIS SESSION (it kept its rows)"
pin  "1 insert, commit: the rows go (vdd04)" \
     "CREATE GLOBAL TEMPORARY TABLE G1 (A INTEGER) ON COMMIT DELETE ROWS; COMMIT; INSERT INTO G1 VALUES (1); COMMIT; SELECT COUNT(*) FROM G1;" "COUNT|0"
pin  "1 no COMMIT between the DDL and the insert" \
     "CREATE GLOBAL TEMPORARY TABLE G2 (A INTEGER) ON COMMIT DELETE ROWS; INSERT INTO G2 VALUES (1); INSERT INTO G2 VALUES (2); COMMIT; SELECT COUNT(*) FROM G2;" "COUNT|0"
pin  "1 ...and on a SECOND commit too (the cache held the empty list)" \
     "CREATE GLOBAL TEMPORARY TABLE G3 (A INTEGER) ON COMMIT DELETE ROWS; COMMIT; INSERT INTO G3 VALUES (1); COMMIT; INSERT INTO G3 VALUES (2); COMMIT; SELECT COUNT(*) FROM G3;" "COUNT|0"
pin  "1 before the COMMIT the rows are there" \
     "CREATE GLOBAL TEMPORARY TABLE G4 (A INTEGER) ON COMMIT DELETE ROWS; COMMIT; INSERT INTO G4 VALUES (1); SELECT COUNT(*) FROM G4; COMMIT;" "COUNT|1"
# COMMIT RETAIN keeps the rows on the engine. Here the rows are purged
# by the plain op_commit isql sends for its OTHER transaction (the DDL
# one) right after it: the purge walks the rows its transaction SEES,
# and a retained commit made them committed. Not new - the same happens
# on the unchanged server for a GTT the fixture made, once the session
# has run any DDL and a COMMIT - so it is recorded, not fixed here: the
# fix is to purge only the rows of the committing transaction's own ids
# (and the ids its retaining commits handed on), which this server does
# not track per transaction yet.
recorded "1 COMMIT RETAIN keeps them (another transaction's commit purges them here)" \
     "CREATE GLOBAL TEMPORARY TABLE G5 (A INTEGER) ON COMMIT DELETE ROWS; COMMIT; INSERT INTO G5 VALUES (1); COMMIT RETAIN; SELECT COUNT(*) FROM G5; COMMIT; SELECT COUNT(*) FROM G5;" "COUNT|1|COUNT|0"
pin  "1 CONTROL a ROLLBACK takes them back" \
     "CREATE GLOBAL TEMPORARY TABLE G7 (A INTEGER) ON COMMIT DELETE ROWS; COMMIT; INSERT INTO G7 VALUES (1); ROLLBACK; SELECT COUNT(*) FROM G7;" "COUNT|0"
pin  "1 CONTROL a PRESERVE ROWS GTT keeps them across the commit" \
     "CREATE GLOBAL TEMPORARY TABLE G6 (A INTEGER) ON COMMIT PRESERVE ROWS; COMMIT; INSERT INTO G6 VALUES (1); COMMIT; SELECT COUNT(*) FROM G6;" "COUNT|1"
pin  "1 CONTROL the catalog row was right all along" \
     "SELECT RDB\$RELATION_TYPE FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME IN ('G1', 'G6') ORDER BY 1;" "RDB\$RELATION_TYPE|4|5"
pin  "1 a fresh attachment sees none (they had been committed)" "SELECT COUNT(*) FROM G1; SELECT COUNT(*) FROM G6;" "COUNT|0|COUNT|0"

echo "--- 2. A COLUMN OF A TEXT DOMAIN CARRIES THE DOMAIN'S CHARSET AND COLLATE (vdd02)"
same "2 the domains and the table, in this session" \
     "CREATE DOMAIN DCI AS VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI; CREATE DOMAIN DCH AS CHAR(4) CHARACTER SET UTF8 COLLATE UNICODE_CI; CREATE DOMAIN DPL AS VARCHAR(10) CHARACTER SET UTF8; CREATE DOMAIN DNO AS VARCHAR(10); CREATE DOMAIN DW AS VARCHAR(10) CHARACTER SET WIN1252; CREATE DOMAIN DBT AS BLOB SUB_TYPE TEXT CHARACTER SET UTF8; COMMIT; CREATE TABLE TC (ID INTEGER, A DCI, C DCH, D DPL, E DNO, F DW, G DBT); COMMIT; INSERT INTO TC VALUES (1, 'AbC', 'Ab', 'AbC', 'AbC', 'AbC', 'AbC'); INSERT INTO TC VALUES (2, 'abd', 'ab', 'abd', 'abd', 'abd', 'abd'); COMMIT; SELECT COUNT(*) FROM TC;"
pin  "2 = finds the other case" "SELECT COUNT(*) FROM TC WHERE A = 'abc';" "COUNT|1"
pin  "2 ...in a CHAR domain too" "SELECT COUNT(*) FROM TC WHERE C = 'AB';" "COUNT|2"
pin  "2 STARTING" "SELECT ID FROM TC WHERE A STARTING 'AB' ORDER BY ID;" "ID|1|2"
pin  "2 LIKE" "SELECT ID FROM TC WHERE A LIKE 'ab%' ORDER BY ID;" "ID|1|2"
pin  "2 CONTAINING" "SELECT ID FROM TC WHERE A CONTAINING 'B' ORDER BY ID;" "ID|1|2"
pin  "2 IN and >" "SELECT ID FROM TC WHERE A IN ('ABC', 'x'); SELECT ID FROM TC WHERE A > 'ABC';" "ID|1|ID|2"
pin  "2 ORDER BY, MIN, MAX" "SELECT A FROM TC ORDER BY A DESC; SELECT MAX(A), MIN(A) FROM TC;" "A|abd|AbC|MAX MIN|abd AbC"
pin  "2 COUNT(DISTINCT)" "SELECT COUNT(DISTINCT A) FROM TC;" "COUNT|2"
pin  "2 the lengths are UTF8's" "SELECT CHAR_LENGTH(A), OCTET_LENGTH(A), CHAR_LENGTH(C), OCTET_LENGTH(C) FROM TC WHERE ID = 1;" "CHAR_LENGTH OCTET_LENGTH CHAR_LENGTH OCTET_LENGTH|3 3 4 4"
pin  "2 against a plain UTF8 column" "SELECT ID FROM TC WHERE A = D ORDER BY ID;" "ID|1|2"
pin  "2 CONTROL a UTF8 domain with no COLLATE is case-sensitive" "SELECT COUNT(*) FROM TC WHERE D = 'abc';" "COUNT|0"
pin  "2 CONTROL ...and a NONE one" "SELECT COUNT(*) FROM TC WHERE E = 'abc';" "COUNT|0"
dsame "2 describe: UTF8, NONE, WIN1252, a UTF8 text blob (it was NONE)" "SELECT A, C, D, E, F, G FROM TC WHERE ID = 1;"
pin  "2 the column's RDB\$COLLATION_ID is NULL (the domain's rules)" \
     "SELECT RDB\$FIELD_NAME, RDB\$COLLATION_ID FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TC' AND RDB\$FIELD_NAME IN ('A', 'D') ORDER BY 1;" \
     "RDB\$FIELD_NAME RDB\$COLLATION_ID|A <null>|D <null>"
pin  "2 ALTER TABLE ADD a domain column" \
     "ALTER TABLE TC ADD Z DCI; COMMIT; UPDATE TC SET Z = 'XyZ'; SELECT COUNT(*) FROM TC WHERE Z = 'xyz'; SELECT RDB\$COLLATION_ID FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TC' AND RDB\$FIELD_NAME = 'Z'; ROLLBACK;" \
     "COUNT|2|RDB\$COLLATION_ID|<null>"
pin  "2 the finding's own shape (vdd02)" \
     "CREATE DOMAIN DZ4 AS VARCHAR(5) CHARACTER SET UTF8 COLLATE UNICODE_CI; COMMIT; CREATE TABLE TZ4 (A DZ4); COMMIT; INSERT INTO TZ4 VALUES ('AbC'); SELECT COUNT(*) FROM TZ4 WHERE A = 'abc'; SELECT A FROM TZ4 WHERE A STARTING 'ab'; COMMIT;" \
     "COUNT|1|A|AbC"
pin  "2 CONTROL a built-in column's COLLATE was right already" \
     "CREATE TABLE TCB (A VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI); COMMIT; INSERT INTO TCB VALUES ('AbC'); SELECT COUNT(*) FROM TCB WHERE A = 'abc'; COMMIT;" "COUNT|1"

echo "--- 3. ALTER TABLE ADD ... DEFAULT (the default was never stored - vdd03)"
pin  "3 the finding's own shape" \
     "CREATE TABLE TT (A INTEGER); COMMIT; ALTER TABLE TT ADD C INTEGER DEFAULT 4; COMMIT; INSERT INTO TT (A) VALUES (2); SELECT * FROM TT; COMMIT;" "A C|2 4"
pin  "3 no COMMIT before the insert" \
     "CREATE TABLE TT2 (A INTEGER); COMMIT; ALTER TABLE TT2 ADD C INTEGER DEFAULT 4; INSERT INTO TT2 (A) VALUES (2); SELECT * FROM TT2; COMMIT;" "A C|2 4"
pin  "3 a row stored before the ADD stays NULL" \
     "ALTER TABLE TOLD ADD C INTEGER DEFAULT 4; COMMIT; INSERT INTO TOLD (A) VALUES (2); SELECT A, C FROM TOLD ORDER BY A; ROLLBACK;" "A C|1 <null>|2 4"
pin  "3 text, numeric, bigint, user, a UTF8 char" \
     "CREATE TABLE TD (K INTEGER); COMMIT; ALTER TABLE TD ADD D VARCHAR(10) DEFAULT 'aB'; ALTER TABLE TD ADD H NUMERIC(9,2) DEFAULT 1.25; ALTER TABLE TD ADD U VARCHAR(10) DEFAULT USER; ALTER TABLE TD ADD I CHAR(3) CHARACTER SET UTF8 DEFAULT 'xz'; ALTER TABLE TD ADD G INTEGER default -7; ALTER TABLE TD ADD N INTEGER DEFAULT NULL; COMMIT; INSERT INTO TD (K) VALUES (1); SELECT D, H, U, I, G, N FROM TD;" \
     "D H U I G N|aB 1.25 SYSDBA xz -7 <null>"
pin  "3 CURRENT_DATE and 'now'" \
     "ALTER TABLE TD ADD F DATE DEFAULT CURRENT_DATE; ALTER TABLE TD ADD J TIMESTAMP DEFAULT 'now'; COMMIT; INSERT INTO TD (K) VALUES (2); SELECT F - CURRENT_DATE, J IS NOT NULL FROM TD WHERE K = 2;" \
     "SUBTRACT BOOL|0 <true>"
pin  "3 an explicit DEFAULT in VALUES" "INSERT INTO TD (K, D, G) VALUES (3, DEFAULT, DEFAULT); SELECT D, G FROM TD WHERE K = 3; ROLLBACK;" "D G|aB -7"
pin  "3 a later session reads it too" "INSERT INTO TT (A) VALUES (5); SELECT C FROM TT WHERE A = 5; ROLLBACK;" "C|4"
pin  "3 a DOMAIN column takes the domain's default" \
     "CREATE DOMAIN DD9 AS INTEGER DEFAULT 9; COMMIT; ALTER TABLE TT ADD E DD9; COMMIT; INSERT INTO TT (A) VALUES (6); SELECT C, E FROM TT WHERE A = 6; ROLLBACK;" "C E|4 9"
pin  "3 the catalog carries it" \
     "SELECT RDB\$FIELD_NAME, RDB\$DEFAULT_VALUE IS NOT NULL FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TT' ORDER BY RDB\$FIELD_POSITION;" \
     "RDB\$FIELD_NAME BOOL|A <false>|C <true>|E <false>"
# a BIGINT literal past 32 bits (blr_int64) as an ALTER TABLE ADD
# default - refused with a bare 42000 until the second pass (section 7)
pin  "3 a BIGINT default past 32 bits (was refused)" \
     "ALTER TABLE TD ADD L BIGINT DEFAULT 9000000000; COMMIT; INSERT INTO TD (K) VALUES (4); SELECT L FROM TD WHERE K = 4; ROLLBACK;" "L|9000000000"
# a NON-ASCII text default of a UTF8 column, from a NONE connection, is
# stored transliterated twice ('é' reads back 'Ã©') - CREATE TABLE's
# default the same, before this change: recorded
recorded "3 a non-ASCII default of a UTF8 column (CREATE TABLE too)" \
     "CREATE TABLE TI (K INTEGER, V VARCHAR(3) CHARACTER SET UTF8 DEFAULT 'é'); COMMIT; INSERT INTO TI (K) VALUES (1); SELECT V, OCTET_LENGTH(V) FROM TI; COMMIT;" "V OCTET_LENGTH|é 2"
pin  "3 CONTROL a CREATE TABLE default was right already" \
     "CREATE TABLE TCD (A INTEGER, C INTEGER DEFAULT 4); COMMIT; INSERT INTO TCD (A) VALUES (1); SELECT C FROM TCD; COMMIT;" "C|4"
# the SOURCE text: the engine keeps the statement's own spelling; this
# server re-spells the keyword upper case (CREATE TABLE too, before this
# change) - a catalog text difference, recorded
recorded "3 RDB\$DEFAULT_SOURCE keeps the statement's spelling" \
     "SET BLOB ALL; SELECT CAST(RDB\$DEFAULT_SOURCE AS VARCHAR(40)) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TD' AND RDB\$FIELD_NAME = 'G';" \
     "CAST|default -7"

echo "--- 4. PSQL OBJECTS UNDER AUTODDL, BEFORE ANY COMMIT (a bare 42000)"
pin  "4 a selectable procedure (p0)" \
     "SET TERM ^; CREATE PROCEDURE P0 RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; END^ SELECT * FROM P0^ COMMIT^ SELECT * FROM P0^" "X|1|X|1"
pin  "4 an executable procedure" \
     "SET TERM ^; CREATE PROCEDURE P1 (A INTEGER) RETURNS (Y INTEGER) AS BEGIN Y = A + 1; END^ EXECUTE PROCEDURE P1(5)^" "Y|6"
pin  "4 a function" "SET TERM ^; CREATE FUNCTION F0 RETURNS INTEGER AS BEGIN RETURN 7; END^ SELECT F0() $DUAL^" "F0|7"
pin  "4 an exception" \
     "SET TERM ^; CREATE EXCEPTION E_NEW 'boom'^ EXECUTE BLOCK AS BEGIN EXCEPTION E_NEW; END^" \
     'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_NEW"|-boom|-At block line: 1, col: 24'
pin  "4 a package function" \
     "SET TERM ^; CREATE PACKAGE PK AS BEGIN FUNCTION PF RETURNS INTEGER; END^ CREATE PACKAGE BODY PK AS BEGIN FUNCTION PF RETURNS INTEGER AS BEGIN RETURN 11; END END^ SELECT PK.PF() $DUAL^" "PF|11"
pin  "4 a trigger fires" \
     "SET TERM ^; CREATE TABLE TTR (A INTEGER)^ CREATE TRIGGER TR0 FOR TTR BEFORE INSERT AS BEGIN NEW.A = NEW.A * 10; END^ INSERT INTO TTR VALUES (2)^ SELECT A FROM TTR^ ROLLBACK^" "A|20"
pin  "4 a sequence" "CREATE SEQUENCE S0; SELECT NEXT VALUE FOR S0 $DUAL; SELECT GEN_ID(S0, 0) $DUAL;" "NEXT_VALUE|1|GEN_ID|1"
pin  "4 CONTROL a view was right already" "CREATE VIEW V0 AS SELECT 3 AS C $DUAL; SELECT * FROM V0;" "C|3"
# the law's other half: the user's own SELECT of the catalog honours the
# snapshot - only the server's metadata walks read the latest commit
pin  "4 a user SELECT of the catalog keeps its snapshot while the procedure runs" \
     "SET TERM ^; CREATE PROCEDURE P9 RETURNS (X INTEGER) AS BEGIN X = 9; SUSPEND; END^ SELECT COUNT(*) FROM RDB\$PROCEDURES WHERE RDB\$PROCEDURE_NAME = 'P9'^ SELECT * FROM P9^ COMMIT^ SELECT COUNT(*) FROM RDB\$PROCEDURES WHERE RDB\$PROCEDURE_NAME = 'P9'^" \
     "COUNT|0|X|9|COUNT|1"
pin  "4 CONTROL ...and of RDB\$RELATIONS" \
     "CREATE TABLE TNEW (A INTEGER); SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'TNEW'; SELECT COUNT(*) FROM TNEW; COMMIT;" "COUNT|0|COUNT|0"

echo "--- 5. AN ADDED COLUMN'S FIELD ID IS THE RELATION'S COUNTER, NOT A DROPPED ONE'S (rddlmeta25)"
pin  "5 drop, then re-add: the old rows read NULL, not the dropped column's bytes" \
     "CREATE TABLE TF (K INTEGER); COMMIT; ALTER TABLE TF ADD C INTEGER DEFAULT 4; COMMIT; INSERT INTO TF (K) VALUES (2); ALTER TABLE TF ALTER COLUMN C SET DEFAULT 9; INSERT INTO TF (K) VALUES (3); ALTER TABLE TF DROP C; ALTER TABLE TF ADD C INTEGER DEFAULT 77; INSERT INTO TF (K) VALUES (5); SELECT K, C FROM TF ORDER BY K; COMMIT;" \
     "K C|2 <null>|3 <null>|5 77"
pin  "5 the catalog: ids off RDB\$RELATIONS.RDB\$FIELD_ID, positions after the highest" \
     "CREATE TABLE TG (K INTEGER, M INTEGER); COMMIT; ALTER TABLE TG ADD C INTEGER; ALTER TABLE TG DROP C; ALTER TABLE TG ADD C INTEGER; ALTER TABLE TG ADD D INTEGER; ALTER TABLE TG DROP M; ALTER TABLE TG ADD E INTEGER; COMMIT; SELECT RDB\$FIELD_NAME, RDB\$FIELD_POSITION, RDB\$FIELD_ID FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TG' ORDER BY 2; SELECT RDB\$FIELD_ID, RDB\$FORMAT FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'TG';" \
     "RDB\$FIELD_NAME RDB\$FIELD_POSITION RDB\$FIELD_ID|K 0 0|C 2 3|D 3 4|E 4 5|RDB\$FIELD_ID RDB\$FORMAT|6 7"
pin  "5 ...and rows stored at every step read back" \
     "INSERT INTO TG (K, C, D, E) VALUES (1, 2, 3, 4); SELECT * FROM TG; ROLLBACK;" "K C D E|1 2 3 4"

echo "--- 6. A CLOCK DEFAULT AT ITS PRECISION (rddlmeta2/5x4)"
pin  "6 TIME DEFAULT CURRENT_TIME / LOCALTIME store whole seconds (ALTER TABLE ADD)" \
     "CREATE TABLE TK (K INTEGER); COMMIT; ALTER TABLE TK ADD X TIME DEFAULT CURRENT_TIME; ALTER TABLE TK ADD X2 TIME DEFAULT LOCALTIME; COMMIT; INSERT INTO TK (K) VALUES (1); SELECT EXTRACT(MILLISECOND FROM X), EXTRACT(MILLISECOND FROM X2) FROM TK; COMMIT;" \
     "EXTRACT EXTRACT|0.0 0.0"
pin  "6 CREATE TABLE: CURRENT_TIME, CURRENT_TIME(2), CURRENT_TIMESTAMP(0), LOCALTIME(1) (were refused)" \
     "CREATE TABLE TK2 (K INTEGER, X TIME DEFAULT CURRENT_TIME, X3 TIME DEFAULT CURRENT_TIME(2), X4 TIMESTAMP DEFAULT CURRENT_TIMESTAMP(0), X5 TIME DEFAULT LOCALTIME (1)); COMMIT; INSERT INTO TK2 (K) VALUES (1); SELECT EXTRACT(MILLISECOND FROM X), MOD(CAST(EXTRACT(MILLISECOND FROM X3) * 10 AS INTEGER), 100), EXTRACT(MILLISECOND FROM X4), MOD(CAST(EXTRACT(MILLISECOND FROM X5) * 10 AS INTEGER), 1000) FROM TK2; COMMIT;" \
     "EXTRACT MOD EXTRACT MOD|0.0 0 0.0 0"
pin  "6 ALTER TABLE ADD ... DEFAULT CURRENT_TIMESTAMP(0)" \
     "ALTER TABLE TK ADD X6 TIMESTAMP DEFAULT CURRENT_TIMESTAMP(0); COMMIT; INSERT INTO TK (K) VALUES (2); SELECT EXTRACT(MILLISECOND FROM X6), CAST(X6 AS DATE) = CURRENT_DATE FROM TK WHERE K = 2; COMMIT;" \
     "EXTRACT BOOL|0.0 <true>"
pin  "6 CONTROL CURRENT_TIMESTAMP is precision 3 (the 4th digit 0)" \
     "CREATE TABLE TK3 (K INTEGER, X TIMESTAMP DEFAULT CURRENT_TIMESTAMP); COMMIT; INSERT INTO TK3 (K) VALUES (1); SELECT MOD(CAST(EXTRACT(MILLISECOND FROM X) * 10 AS INTEGER), 10) FROM TK3; COMMIT;" "MOD|0"

echo "--- 7. LITERAL DEFAULTS PAST 32 BITS, WITH AN EXPONENT, BOOLEAN (rddlmeta5x*)"
pin  "7 CREATE TABLE: blr_int64, blr_int128, blr_double, blr_bool, UNKNOWN (were refused)" \
     "CREATE TABLE TL (K INTEGER, A BIGINT DEFAULT 9000000000, B NUMERIC(18,2) DEFAULT 123456789012.34, C INT128 DEFAULT -99999999999999999999, E NUMERIC(9,2) DEFAULT 1e2, F BOOLEAN DEFAULT TRUE, G BOOLEAN DEFAULT FALSE, N BOOLEAN DEFAULT UNKNOWN, D DOUBLE PRECISION DEFAULT 1.5e-3, H BIGINT DEFAULT -2147483649); COMMIT; INSERT INTO TL (K) VALUES (1); SELECT A, B, C, E, F, G, N, D, H FROM TL; COMMIT;" \
     "A B C E F G N D H|9000000000 123456789012.34 -99999999999999999999 100.00 <true> <false> <null> 0.001500000000000000 -2147483649"
pin  "7 ALTER TABLE ADD: INT128 max, NUMERIC(38,2), DECFLOAT(34) 1e300, BOOLEAN (were refused)" \
     "CREATE TABLE TM (K INTEGER); INSERT INTO TM VALUES (1); COMMIT; ALTER TABLE TM ADD XI INT128 DEFAULT 170141183460469231731687303715884105727; ALTER TABLE TM ADD XN NUMERIC(38,2) DEFAULT 12345678901234567890.12; ALTER TABLE TM ADD XD DECFLOAT(34) DEFAULT 1e300; ALTER TABLE TM ADD XB BOOLEAN DEFAULT TRUE; COMMIT; INSERT INTO TM (K) VALUES (2); SELECT K, XI, XN, XD, XB FROM TM ORDER BY K; COMMIT;" \
     "K XI XN XD XB|1 <null> <null> <null> <null>|2 170141183460469231731687303715884105727 12345678901234567890.12 1.0000000000000001E+300 <true>"
pin  "7 CONTROL a 32-bit literal default was right already" \
     "CREATE TABLE TL2 (K INTEGER, A BIGINT DEFAULT 2147483647, B NUMERIC(9,2) DEFAULT -0.5); COMMIT; INSERT INTO TL2 (K) VALUES (1); SELECT A, B FROM TL2; COMMIT;" "A B|2147483647 -0.50"

echo "--- 8. A TEXT DEFAULT OF A BLOB COLUMN (rddlmeta7 - every INSERT that omitted it refused)"
pin  "8 ALTER TABLE ADD ... BLOB SUB_TYPE TEXT DEFAULT, then an INSERT that omits it" \
     "CREATE TABLE TB (K INTEGER); COMMIT; ALTER TABLE TB ADD XK BLOB SUB_TYPE TEXT DEFAULT 'bl'; COMMIT; INSERT INTO TB (K) VALUES (2); INSERT INTO TB (K, XK) VALUES (3, 'zz'); SELECT K, CAST(XK AS VARCHAR(10)) FROM TB ORDER BY K; COMMIT;" \
     "K CAST|2 bl|3 zz"
pin  "8 CREATE TABLE's text and binary blob defaults" \
     "CREATE TABLE TB2 (K INTEGER, XK BLOB SUB_TYPE TEXT DEFAULT 'bl', XB BLOB DEFAULT 'bb'); COMMIT; INSERT INTO TB2 (K) VALUES (2); SELECT CAST(XK AS VARCHAR(10)), CAST(XB AS VARCHAR(10)), OCTET_LENGTH(XB) FROM TB2; COMMIT;" \
     "CAST CAST OCTET_LENGTH|bl bb 2"

echo "--- 9. ALTER TABLE ADD ... NOT NULL / IDENTITY (refused, or an identity that read NULL)"
pin  "9 DEFAULT 1 NOT NULL over a populated table: the old row reads the default" \
     "CREATE TABLE TN (K INTEGER); INSERT INTO TN VALUES (1); COMMIT; ALTER TABLE TN ADD XA INTEGER DEFAULT 1 NOT NULL; COMMIT; INSERT INTO TN (K) VALUES (2); SELECT K, XA FROM TN ORDER BY K; COMMIT;" \
     "K XA|1 1|2 1"
pin  "9 every measured type's default, read by the row stored before it" \
     "CREATE TABLE TP (K INTEGER); INSERT INTO TP VALUES (1); COMMIT; ALTER TABLE TP ADD A NUMERIC(9,2) DEFAULT 1.25 NOT NULL; ALTER TABLE TP ADD B BIGINT DEFAULT 9000000000 NOT NULL; ALTER TABLE TP ADD C CHAR(4) DEFAULT 'ab' NOT NULL; ALTER TABLE TP ADD D VARCHAR(5) CHARACTER SET UTF8 DEFAULT 'xy' NOT NULL; ALTER TABLE TP ADD E CHAR(3) CHARACTER SET UTF8 DEFAULT 'q' NOT NULL; ALTER TABLE TP ADD G VARCHAR(10) DEFAULT USER NOT NULL; ALTER TABLE TP ADD H BOOLEAN DEFAULT TRUE NOT NULL; ALTER TABLE TP ADD I SMALLINT DEFAULT 7 NOT NULL; ALTER TABLE TP ADD J DOUBLE PRECISION DEFAULT 1.5 NOT NULL; ALTER TABLE TP ADD L NUMERIC(18,4) DEFAULT 3 NOT NULL; COMMIT; SELECT * FROM TP;" \
     "K A B C D E G H I J L|1 1.25 9000000000 ab xy q SYSDBA <true> 7 1.500000000000000 3.0000"
pin  "9 DATE DEFAULT CURRENT_DATE NOT NULL: the ALTER's date" \
     "ALTER TABLE TN ADD F DATE DEFAULT CURRENT_DATE NOT NULL; COMMIT; SELECT K, F = CURRENT_DATE FROM TN ORDER BY K;" "K BOOL|1 <true>|2 <true>"
pin  "9 a later ALTER keeps the old rows' default (the format carries it)" \
     "ALTER TABLE TN ADD W INTEGER; COMMIT; ALTER TABLE TN DROP W; COMMIT; SELECT K, XA FROM TN ORDER BY K;" "K XA|1 1|2 1"
pin  "9 NOT NULL with no default over rows: the engine's 22006" \
     "ALTER TABLE TN ADD XN INTEGER NOT NULL;" \
     'Statement failed, SQLSTATE = 22006|unsuccessful metadata update|-Cannot make field "XN" of table "PUBLIC"."TN" NOT NULL because there are NULLs present'
pin  "9 an IDENTITY over rows: the same 22006" \
     "ALTER TABLE TN ADD ID2 INTEGER GENERATED ALWAYS AS IDENTITY;" \
     'Statement failed, SQLSTATE = 22006|unsuccessful metadata update|-Cannot make field "ID2" of table "PUBLIC"."TN" NOT NULL because there are NULLs present'
pin  "9 ...and neither was added" \
     "SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TN';" "COUNT|3"
pin  "9 NOT NULL, a default and an IDENTITY over an empty table: the catalog" \
     "CREATE TABLE TE (K INTEGER); COMMIT; ALTER TABLE TE ADD X INTEGER NOT NULL; ALTER TABLE TE ADD Y INTEGER DEFAULT 5 NOT NULL; ALTER TABLE TE ADD ID INTEGER GENERATED BY DEFAULT AS IDENTITY; COMMIT; SELECT RDB\$FIELD_NAME, RDB\$NULL_FLAG, RDB\$IDENTITY_TYPE, RDB\$GENERATOR_NAME IS NOT NULL FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TE' ORDER BY RDB\$FIELD_POSITION; SELECT RC.RDB\$CONSTRAINT_TYPE, CC.RDB\$TRIGGER_NAME FROM RDB\$RELATION_CONSTRAINTS RC JOIN RDB\$CHECK_CONSTRAINTS CC ON CC.RDB\$CONSTRAINT_NAME = RC.RDB\$CONSTRAINT_NAME WHERE RC.RDB\$RELATION_NAME = 'TE' ORDER BY 2;" \
     "RDB\$FIELD_NAME RDB\$NULL_FLAG RDB\$IDENTITY_TYPE BOOL|K <null> <null> <false>|X 1 <null> <false>|Y 1 <null> <false>|ID 1 1 <true>|RDB\$CONSTRAINT_TYPE RDB\$TRIGGER_NAME|NOT NULL X|NOT NULL Y"
pin  "9 the added identity numbers the rows (it read NULL), NOT NULL holds" \
     "INSERT INTO TE (K, X) VALUES (1, 2); INSERT INTO TE (K, X) VALUES (1, 2); SELECT X, Y, ID FROM TE ORDER BY ID; INSERT INTO TE (K) VALUES (1); COMMIT;" \
     'X Y ID|2 5 1|2 5 2|Statement failed, SQLSTATE = 23000|validation error for column "PUBLIC"."TE"."X", value "*** null ***"'
pin  "9 SET NOT NULL over NULLs: the same vector (was a bare 42000)" \
     "CREATE TABLE TSN (K INTEGER); INSERT INTO TSN VALUES (NULL); COMMIT; ALTER TABLE TSN ALTER K SET NOT NULL;" \
     'Statement failed, SQLSTATE = 22006|unsuccessful metadata update|-Cannot make field "K" of table "PUBLIC"."TSN" NOT NULL because there are NULLs present'
# `DEFAULT NULL NOT NULL` is refused (a bare 42000) where the engine
# raises its own -204 at prepare: both refuse, the vector differs
recorded "9 DEFAULT NULL NOT NULL: both refuse, the vector differs" \
     "ALTER TABLE TE ADD XZ INTEGER DEFAULT NULL NOT NULL;" \
     "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"TE\" failed|-SQL error code = -204|-can not define a not null column with NULL as default value|-invalid clause --- 'default null not null'"
# an inline CHECK on ALTER TABLE ADD is refused (a bare 42000) where
# the engine adds the column and its constraint
recorded "9 ADD ... CHECK (...) inline: refused here" \
     "ALTER TABLE TM ADD XQ VARCHAR(5) DEFAULT 'q' CHECK (XQ <> 'z'); COMMIT; INSERT INTO TM (K) VALUES (3); SELECT XQ FROM TM WHERE K = 3; ROLLBACK;" "XQ|q"

echo "--- 10. A CASE-INSENSITIVE COLUMN IN A VALUE EXPRESSION (rddlmeta15 - a byte compare answered)"
pin  "10 CASE / IIF / a boolean value / IN / DECODE / NULLIF / IS NOT DISTINCT over the domain column" \
     "SELECT CASE WHEN A = 'abc' THEN 1 ELSE 0 END, IIF(A = 'abc', 1, 0), A = 'abc', A IN ('abc'), DECODE(A, 'abc', 1, 0), NULLIF(A, 'abc'), A IS NOT DISTINCT FROM 'abc' FROM TC WHERE ID = 1;" \
     "CASE CASE BOOL BOOL DECODE CASE BOOL|1 1 <true> <true> 1 <null> <true>"
pin  "10 SUM(IIF(..)), IIF in a WHERE, a correlated EXISTS" \
     "SELECT SUM(IIF(A = 'abc', 1, 0)) FROM TC; SELECT ID FROM TC WHERE IIF(A = 'ABC', 1, 0) = 1; SELECT COUNT(*) FROM RDB\$DATABASE WHERE EXISTS (SELECT * FROM TC WHERE TC.A = 'abc');" \
     "SUM|1|ID|1|COUNT|1"
pin  "10 ...and a declared UNICODE_CI column" \
     "SELECT IIF(A = 'abc', 1, 0), NULLIF(A, 'ABC'), A IN ('x', 'abc') FROM TCB;" "CASE CASE BOOL|1 <null> <true>"
dsame "10 NULLIF's describe is the first operand's" "SELECT NULLIF(A, 'abc'), NULLIF(A, 'x') FROM TC WHERE ID = 1;"
pin  "10 CONTROL a case-sensitive UTF8 column stays case-sensitive" \
     "SELECT IIF(D = 'abc', 1, 0), NULLIF(D, 'abc'), D IN ('abc') FROM TC WHERE ID = 1;" "CASE CASE BOOL|0 AbC <false>"
pin  "10 COUNT(DISTINCT) over two spellings of one CI value is one" \
     "CREATE TABLE TCD2 (ID INTEGER, A DCI); COMMIT; INSERT INTO TCD2 VALUES (1, 'AbC'); INSERT INTO TCD2 VALUES (2, 'abc'); INSERT INTO TCD2 VALUES (3, 'abd'); SELECT COUNT(DISTINCT A) FROM TCD2; COMMIT;" "COUNT|2"
# An EXPRESSION over a collated column carries the collation too
# (refused here until the round-3 collation reader of 2026-09-26; it
# had compared bytes)
pin "10 UPPER(ci) = 'abc': the collation compares, not the bytes" \
     "SELECT IIF(UPPER(A) = 'abc', 1, 0) FROM TC WHERE ID = 1;" "CASE|1"
# GROUP BY / DISTINCT over a case-insensitive column is REFUSED by rule
# (coll_groupable): the engine merges the spellings and returns one of
# them by no rule this server can reproduce (measured: {AbC, abc, abd}
# groups as abc, abd). The domain column meets that rule now that it
# carries its collation; before, it was a byte-compared NONE column and
# answered two groups where the engine has one.
# PROMOTED 2026-09-26 (serve-real-collkey): the surviving spelling follows
# the engine's sort record order and this server answers it now
pin  "10 GROUP BY a CI column: the surviving spelling follows the record order" \
     "SELECT A FROM TCD2 GROUP BY A;" "A|abc|abd"

echo "--- 11. A NONE CONNECTION'S NON-ASCII TEXT INTO A UTF8 COLUMN IS COUNTED IN UTF8 CHARACTERS (rddlmeta13)"
pin  "11 'é' into a CHAR(1) / VARCHAR(2) UTF8 domain column, and a declared one" \
     "CREATE DOMAIN D_CH1 AS CHAR(1) CHARACTER SET UTF8; CREATE DOMAIN D_VC2 AS VARCHAR(2) CHARACTER SET UTF8; COMMIT; CREATE TABLE TU8 (ID INTEGER, N D_CH1, V D_VC2, B CHAR(1) CHARACTER SET UTF8); COMMIT; INSERT INTO TU8 (ID, N) VALUES (2, 'é'); INSERT INTO TU8 (ID, V) VALUES (3, 'éé'); INSERT INTO TU8 (ID, B) VALUES (4, 'é'); SELECT ID, OCTET_LENGTH(N), OCTET_LENGTH(V), CHAR_LENGTH(V), OCTET_LENGTH(B) FROM TU8 ORDER BY ID; COMMIT;" \
     "ID OCTET_LENGTH OCTET_LENGTH CHAR_LENGTH OCTET_LENGTH|2 2 <null> <null> <null>|3 <null> 4 2 <null>|4 <null> <null> <null> 2"
pin  "11 one character too many is 22001 with the engine's numbers" \
     "INSERT INTO TU8 (ID, N) VALUES (5, 'éé'); INSERT INTO TU8 (ID, V) VALUES (6, 'ééé');" \
     "Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 1, actual 2|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 2, actual 3"

echo "--- 12. A ROLLBACK OF DDL TAKES THE CACHED SCHEMA BACK (rddlmeta19)"
pin  "12 AUTODDL OFF: ADD, a SELECT that saw it, ROLLBACK, the column is gone" \
     "SET AUTODDL OFF; CREATE TABLE TQ (A INTEGER DEFAULT 3, B VARCHAR(5) DEFAULT 'z'); COMMIT; ALTER TABLE TQ ADD C INTEGER DEFAULT 8; INSERT INTO TQ (A) VALUES (1); SELECT * FROM TQ; ROLLBACK; INSERT INTO TQ (A) VALUES (2); SELECT * FROM TQ; COMMIT;" \
     "A B C|1 z 8|A B|2 z"
pin  "12 CONTROL with no SELECT in between it was right already" \
     "SET AUTODDL OFF; ALTER TABLE TQ ADD D INTEGER DEFAULT 8; INSERT INTO TQ (A) VALUES (3); ROLLBACK; SELECT * FROM TQ; COMMIT;" "A B|2 z"

echo "--- 13. ALTER SEQUENCE ... INCREMENT / RESTART (rddlmeta29 - a bare 42000)"
pin  "13 INCREMENT BY: the next value steps by it, the row carries it" \
     "CREATE SEQUENCE SF START WITH 10 INCREMENT BY 5; COMMIT; ALTER SEQUENCE SF INCREMENT BY 100; SELECT NEXT VALUE FOR SF FROM RDB\$DATABASE; SELECT NEXT VALUE FOR SF FROM RDB\$DATABASE; COMMIT; SELECT RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'SF';" \
     "NEXT_VALUE|105|NEXT_VALUE|205|RDB\$GENERATOR_INCREMENT|100"
# isql's snapshot, begun before the ALTER, still reads the OLD step off
# RDB$GENERATORS on the engine; here that SELECT already sees the new
# one - the catalog-snapshot gap the first pass recorded for a dropped
# column, a new domain and a new sequence (a user SELECT of those rows
# is not held to its snapshot here). Recorded, not fixed.
recorded "13 the old snapshot's SELECT of RDB\$GENERATORS reads the old step" \
     "CREATE SEQUENCE S5 START WITH 10 INCREMENT BY 5; COMMIT; ALTER SEQUENCE S5 INCREMENT BY 100; SELECT RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'S5'; COMMIT;" \
     "RDB\$GENERATOR_INCREMENT|5"
pin  "13 RESTART WITH + INCREMENT BY, a bare RESTART, INCREMENT without BY" \
     "CREATE SEQUENCE S2 START WITH 1; ALTER SEQUENCE S2 INCREMENT BY 3; SELECT NEXT VALUE FOR S2 FROM RDB\$DATABASE; ALTER SEQUENCE S2 RESTART WITH 50 INCREMENT BY 2; SELECT NEXT VALUE FOR S2 FROM RDB\$DATABASE; ALTER SEQUENCE S2 RESTART; SELECT NEXT VALUE FOR S2 FROM RDB\$DATABASE; ALTER SEQUENCE S2 INCREMENT 7; SELECT NEXT VALUE FOR S2 FROM RDB\$DATABASE; COMMIT;" \
     "NEXT_VALUE|3|NEXT_VALUE|50|NEXT_VALUE|1|NEXT_VALUE|8"
pin  "13 INCREMENT BY 0: the engine's vector" \
     "ALTER SEQUENCE S2 INCREMENT BY 0; SELECT GEN_ID(S2, 0) FROM RDB\$DATABASE;" \
     'Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER SEQUENCE "PUBLIC"."S2" failed|-INCREMENT BY 0 is an illegal option for sequence "PUBLIC"."S2"|GEN_ID|8'
pin  "13 AUTODDL OFF: a ROLLBACK takes the new step back" \
     "SET AUTODDL OFF; CREATE SEQUENCE S3 START WITH 1 INCREMENT BY 1; COMMIT; ALTER SEQUENCE S3 INCREMENT BY 50; ROLLBACK; SELECT NEXT VALUE FOR S3 FROM RDB\$DATABASE; COMMIT; SELECT RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'S3';" \
     "NEXT_VALUE|1|RDB\$GENERATOR_INCREMENT|1"
pin  "13 CONTROL RESTART WITH alone was right already" \
     "CREATE SEQUENCE S4 START WITH 1 INCREMENT BY 2; COMMIT; ALTER SEQUENCE S4 RESTART WITH 20; SELECT NEXT VALUE FOR S4 FROM RDB\$DATABASE; COMMIT;" "NEXT_VALUE|20"

echo "--- 14. DROP OF A COLUMN ANOTHER OBJECT READS (rddlmeta18 - it dropped)"
pin  "14 a trigger reads it: cannot delete, 1 dependency" \
     "CREATE TABLE TDP (A INTEGER, B INTEGER, C INTEGER, D INTEGER, E INTEGER); COMMIT; CREATE VIEW VDP AS SELECT A, C FROM TDP; SET TERM ^; CREATE TRIGGER TRDP FOR TDP BEFORE INSERT AS BEGIN NEW.B = 99; END^ CREATE PROCEDURE PDP RETURNS (X INTEGER) AS BEGIN FOR SELECT D FROM TDP INTO :X DO SUSPEND; END^ SET TERM ;^ COMMIT; ALTER TABLE TDP DROP B;" \
     'Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-cannot delete|-COLUMN "PUBLIC"."TDP"."B"|-there are 1 dependencies'
pin  "14 a view selects it: DYN 52" \
     "ALTER TABLE TDP DROP C;" \
     'Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE "PUBLIC"."TDP" failed|-Column "C" from table "PUBLIC"."TDP" is referenced in view "PUBLIC"."VDP"'
pin  "14 a procedure reads it" \
     "ALTER TABLE TDP DROP D;" \
     'Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-cannot delete|-COLUMN "PUBLIC"."TDP"."D"|-there are 1 dependencies'
pin  "14 ...one nothing reads drops, the three read ones stay" \
     "ALTER TABLE TDP DROP E; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TDP' ORDER BY RDB\$FIELD_POSITION;" \
     "RDB\$FIELD_NAME|A|B|C|D"

pin  "14 CONTROL an unreferenced column of a plain table drops" \
     "CREATE TABLE TDQ (A INTEGER, B INTEGER); COMMIT; ALTER TABLE TDQ DROP B; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TDQ';" \
     "RDB\$FIELD_NAME|A"

echo "--- 15. A KEY OVER A CASE-INSENSITIVE COLUMN (rddlmeta21/22) - refused, not byte-keyed"
# The engine keys a collated column by its collation's SORT key (ICU's
# for UNICODE_CI); this writer could only stamp a byte index, which
# stored 'abc' beside 'AbC' under a PRIMARY KEY and refused an FK child
# 'KEY' of a parent 'Key'. The index (and so the table) is refused now.
recorded "15 PRIMARY KEY over a UNICODE_CI domain column: refused here" \
     "CREATE DOMAIN DKCI AS VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI; COMMIT; CREATE TABLE TUK (A DKCI NOT NULL CONSTRAINT PK_TUK PRIMARY KEY); COMMIT; INSERT INTO TUK VALUES ('AbC'); INSERT INTO TUK VALUES ('abc'); SELECT COUNT(*) FROM TUK; COMMIT;" \
     'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "PK_TUK" on table "PUBLIC"."TUK"|-Problematic key value is ("A" = '"'abc'"')|COUNT|1'
recorded "15 ...a UNIQUE over a declared one, and an FK child of a CI parent" \
     "CREATE TABLE TUP (A VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI NOT NULL CONSTRAINT PK_TUP PRIMARY KEY); CREATE TABLE TUC (A VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI REFERENCES TUP (A)); COMMIT; INSERT INTO TUP VALUES ('Key'); INSERT INTO TUC VALUES ('KEY'); SELECT COUNT(*) FROM TUC; COMMIT;" \
     "COUNT|1"
pin  "15 CONTROL a key over a case-sensitive UTF8 column stays" \
     "CREATE TABLE TUS (A VARCHAR(10) CHARACTER SET UTF8 NOT NULL CONSTRAINT PK_TUS PRIMARY KEY); COMMIT; INSERT INTO TUS VALUES ('AbC'); INSERT INTO TUS VALUES ('abc'); SELECT COUNT(*) FROM TUS; COMMIT;" "COUNT|2"

echo "--- 16. RECORDED: DDL ON A TABLE ISQL'S SNAPSHOT HAS WRITTEN (rddlmeta32)"
# The engine refuses ALTER ... SET NOT NULL, ADD ... IDENTITY, CREATE
# INDEX and ADD CONSTRAINT with 40001 "object TABLE ... is in use" while
# the session's other transaction has written the table; this server
# holds no such lock and runs them. Recorded, not fixed.
recorded "16 SET NOT NULL on a table this session wrote: the engine's 40001" \
     "CREATE TABLE TIU (A INTEGER, B INTEGER); COMMIT; INSERT INTO TIU VALUES (1, 2); ALTER TABLE TIU ALTER B SET NOT NULL; ROLLBACK;" \
     'Statement failed, SQLSTATE = 40001|lock conflict on no wait transaction|-unsuccessful metadata update|-object TABLE "PUBLIC"."TIU" is in use'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-ddlmeta-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "--- 17. THE ENGINE READS THIS SERVER'S FILE (the format defaults, the BLR, the field ids)"
# the server stops; the ENGINE opens both files and must answer the same
# of each - what it reads here is exactly what this server wrote
kill $srv 2>/dev/null; wait $srv 2>/dev/null
eread() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$REAL:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng file=[$ev]"; echo "     fc file =[$fv]"; fail=1
    else echo "OK   $1 [${ev:0:160}]"; fi
}
eread "17 the old rows read the NOT NULL defaults this server put in the format" \
     "SELECT * FROM TP; SELECT K, XA FROM TN ORDER BY K;"
eread "17 the format blobs are byte-identical" \
     "SET BLOB ALL; SELECT R.RDB\$RELATION_NAME, F.RDB\$FORMAT, CAST(F.RDB\$DESCRIPTOR AS VARCHAR(8000) CHARACTER SET OCTETS) FROM RDB\$FORMATS F JOIN RDB\$RELATIONS R ON R.RDB\$RELATION_ID = F.RDB\$RELATION_ID WHERE R.RDB\$RELATION_NAME IN ('TP', 'TE', 'TG', 'TF') ORDER BY 1, 2;"
eread "17 the default BLR is the engine's own" \
     "SELECT RDB\$RELATION_NAME, RDB\$FIELD_NAME, CAST(RDB\$DEFAULT_VALUE AS VARCHAR(80) CHARACTER SET OCTETS) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME IN ('TL', 'TK2', 'TM', 'TB2') AND RDB\$FIELD_NAME <> 'XQ' ORDER BY 1, RDB\$FIELD_POSITION;"
eread "17 the field ids and the drop/re-add rows" "SELECT K, C FROM TF ORDER BY K; SELECT * FROM TG;"
eread "17 the sequences' steps and values" \
     "SELECT RDB\$GENERATOR_NAME, RDB\$GENERATOR_INCREMENT, GEN_ID(SF, 0) FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME IN ('SF', 'S2', 'S3') ORDER BY 1;"
eread "17 the engine inserts into the added identity and NOT NULL columns" \
     "INSERT INTO TE (K, X) VALUES (7, 7); SELECT X, Y, ID FROM TE ORDER BY ID; INSERT INTO TN (K) VALUES (3); SELECT K, XA FROM TN ORDER BY K; ROLLBACK;"

echo "ran $ran checks"
if [ "$ran" -lt 100 ]; then echo "FAIL only $ran checks ran (floor 100)"; fail=1; fi
exit $fail
