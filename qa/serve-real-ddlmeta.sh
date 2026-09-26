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
# a BIGINT literal past 32 bits as an ALTER TABLE ADD default is refused
# (a bare 42000) where the engine takes it - a clean refusal, recorded
recorded "3 a BIGINT default past 32 bits (refused here)" \
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

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-ddlmeta-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 45 ]; then echo "FAIL only $ran checks ran (floor 45)"; fail=1; fi
exit $fail
