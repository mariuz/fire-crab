#!/bin/bash
# DDL AND DML FORMS THIS SERVER REFUSED WHERE THE ENGINE ANSWERS - the
# multi-agent hunt's "DDL/DML refusals" cluster, each member re-measured
# on engine 2182 and matched cell by cell, the engine pinned in every one.
#
#   1. UPDATE / DELETE ... ORDER BY ... ROWS: the statement without the
#      tail plans as before and the tail picks and orders its targets -
#      FIRST (n - m) + 1 SKIP m - 1 over a SORT (parse.y rows_clause),
#      the bounds converted with MOV_get_int64's rounding (`rows 1.5` is
#      two rows), NULL as 0, the count judged before the skip (`rows 0 to
#      -5` HY000 FETCH/FIRST, `rows 0 to 2` 42000 OFFSET/SKIP), a count of
#      0 opening nothing. RETURNING lists the rows in that order.
#   2. IF [NOT] EXISTS on CREATE / DROP / ALTER TABLE ADD|DROP: the guard
#      read against the kind's namespace, the statement doing nothing or
#      running without it through the unguarded statement's own planner.
#   3. CREATE OR ALTER SEQUENCE (START WITH over an existing one is a
#      RESTART WITH, RDB$INITIAL_VALUE kept), GEN_ID with a decimal, a
#      string or a NULL step (rounded, converted, NULL without advancing).
#   4. RDB$DEFAULT_SOURCE as written - `DeFaUlT   42` - where this server
#      rebuilt `DEFAULT 42`; typed DATE / TIME / TIMESTAMP literal
#      defaults (blr_sql_date / blr_sql_time / blr_timestamp).
#   5. UPDATE ... SET <col> = DEFAULT; UPDATE OR INSERT with no column
#      list; RETURNING a COMPUTED column.
#   6. ALTER INDEX / SET STATISTICS INDEX with a lower-case name (the
#      lookup compared the name as written); ALTER COLUMN ... TO (rename,
#      its index segments and NOT NULL link following, the engine's
#      dependency / constraint refusals with their vectors); DROP NOT NULL
#      over a nullable column (a no-op); SET INCREMENT on an identity;
#      ALTER COLUMN TYPE over the engine's wider matrix where the stored
#      values present in the new type (exact rescale, to DOUBLE PRECISION,
#      DATE to TIMESTAMP, CHAR <-> VARCHAR), VARCHAR's RDB$FIELD_LENGTH the
#      byte length (a pre-existing +2).
#   7. CAST(<v> AS <domain>) and CAST(<v> AS TYPE OF <domain>): the
#      domain's type spelled out.
#   8. RECORDED, still refused (never a wrong answer): an INSERT into a
#      table with an expression, partial, DECFLOAT or TIME WITH TIME ZONE
#      index; COMPUTED BY / GENERATED ALWAYS AS beyond the integer
#      arithmetic surface; ALTER TABLE ADD <column> with an inline CHECK
#      or UNIQUE; a CAST to a domain with a NOT NULL or CHECK (the
#      validation is not reproduced) or an explicit collation; a domain
#      column with a COLLATE override; ROWS with a `?` or a subquery, a
#      PLAN in a DML; the BLR-offset vector of an undefined generator; the
#      BIGINT -> DOUBLE conversion vector. And a recorded DIVERGENCE: a
#      RETURNING through a WITH CHECK OPTION view answers 0/0 on INSERT
#      and no row on UPDATE on the engine (an engine quirk; this server
#      answers the real row).
#   9. The ENGINE reads fc's file after all of it, and gfix is clean.
#  10. The review of c697f49: a rescale that keeps the storage word
#      raises 22003 when a stored value no longer fits it (it wrapped);
#      a quoted sequence name that is not its own fold is refused by
#      CREATE OR ALTER and the guard (it restarted the unquoted
#      namesake); the guard only in the grammar's directions (DROP ...
#      IF NOT EXISTS, CREATE ... IF EXISTS, ALTER DOMAIN IF EXISTS are
#      -104, and one wrote a default); ALTER TABLE ... IF [NOT] EXISTS on
#      a missing table or a view is 42S02; a step of -2147483648 is -104;
#      an exception name of two words is -104 (it created "E3 X").
#  11. The review of the merged fc/integ4: an UPDATE of a row a rescale
#      pushed out of its storage word raises 22003 whichever column it
#      sets (it stored NULL and committed it), a DELETE's RETURNING only
#      where it presents the column; a catalog patch after a rolled-back
#      ALTER starts from the version the catalog sees (a rolled-back
#      rename came back with the next SET DEFAULT); an INACTIVE index
#      keeps irt_descending and is never read through (a reactivated
#      DESC index missed rows), and an irt_commit slot the engine left
#      is neither read nor enforced; an index build keys the visible
#      version (a rolled-back duplicate refused CREATE UNIQUE INDEX);
#      DROP DEFAULT of a default the column does not own is DYN 229/230.
#
# Usage: qa/serve-real-ddlref.sh [port]   (default 5950)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5950}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/ddlref-eng.fdb"; FC="$D/ddlref-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE R1 (ID INTEGER PRIMARY KEY, N INTEGER, S VARCHAR(5));
CREATE TABLE R2 (ID INTEGER, N INTEGER);
CREATE TABLE IE1 (ID INTEGER, N INTEGER);
CREATE TABLE IE2 (A INTEGER);
CREATE SEQUENCE IES START WITH 5;
CREATE INDEX IEI ON IE1 (N);
CREATE DOMAIN IED INTEGER;
CREATE EXCEPTION IEE 'x';
CREATE ROLE IER;
CREATE SEQUENCE S5 START WITH 5 INCREMENT 2;
CREATE SEQUENCE S7;
CREATE SEQUENCE S9 START WITH 100;
CREATE SEQUENCE S8;
CREATE TABLE TP (ID INTEGER PRIMARY KEY, NAME VARCHAR(10) DEFAULT 'dflt', N INTEGER);
CREATE DOMAIN DDEF INTEGER DEFAULT 42;
CREATE TABLE TPD (ID INTEGER, D DDEF, E DDEF DEFAULT 7, B BOOLEAN DEFAULT TRUE, TS DATE DEFAULT CURRENT_DATE, IDN INTEGER GENERATED BY DEFAULT AS IDENTITY);
CREATE TABLE TCOMP (A INTEGER, B INTEGER, C COMPUTED BY (A * B), D COMPUTED BY (C + 1));
CREATE TABLE TQ (ID INTEGER, NAME VARCHAR(10));
CREATE TABLE AT1 (ID INTEGER NOT NULL PRIMARY KEY, N BIGINT, B BOOLEAN, F DOUBLE PRECISION, K INTEGER NOT NULL, Q INTEGER);
CREATE INDEX AT1_N ON AT1 (N);
CREATE INDEX AT1_Q ON AT1 (Q);
CREATE TABLE ATID (ID INTEGER GENERATED ALWAYS AS IDENTITY, V INTEGER);
CREATE TABLE RN (ID INTEGER NOT NULL PRIMARY KEY, K INTEGER NOT NULL, V INTEGER, W INTEGER CHECK (W > 0), X INTEGER, C COMPUTED BY (X + 1), U INTEGER UNIQUE, Q INTEGER);
CREATE INDEX RNQ ON RN (Q);
CREATE TABLE TY (ID INTEGER, I INTEGER, S SMALLINT, FL FLOAT, AMT NUMERIC(10,2), N52 NUMERIC(5,2), DT DATE, V VARCHAR(5), C CHAR(3), BI BIGINT, IX INTEGER, NN NUMERIC(9,2));
CREATE DOMAIN D_POS INTEGER DEFAULT 5 CHECK (VALUE > 0);
CREATE DOMAIN D_NN INTEGER NOT NULL;
CREATE DOMAIN D_VC VARCHAR(5) CHARACTER SET UTF8;
CREATE DOMAIN D_NUM NUMERIC(9,2);
CREATE DOMAIN D_INT INTEGER;
CREATE DOMAIN D_TS TIMESTAMP;
CREATE DOMAIN D_DBL DOUBLE PRECISION;
CREATE DOMAIN D_DEC DECIMAL(12,3);
CREATE DOMAIN D_CH CHAR(4);
CREATE DOMAIN D_BOOL BOOLEAN;
CREATE DOMAIN D_CI VARCHAR(5) CHARACTER SET UTF8 COLLATE UNICODE_CI;
CREATE TABLE TT (A INTEGER, S VARCHAR(10));
CREATE TABLE EX1 (B VARCHAR(10));
CREATE INDEX EX1_I ON EX1 COMPUTED BY (UPPER(B));
CREATE TABLE EX3 (A INTEGER);
CREATE UNIQUE INDEX EX3_I ON EX3 (A) WHERE A IS NOT NULL;
CREATE TABLE DFC (X DECFLOAT(34) UNIQUE);
CREATE TABLE X3 (A TIME WITH TIME ZONE);
CREATE INDEX X3I ON X3 (A);
CREATE TABLE VB (ID INTEGER, N INTEGER);
CREATE TABLE TC2 (ID INTEGER PRIMARY KEY);
CREATE TABLE TC3 (ID INTEGER PRIMARY KEY);
CREATE TABLE TYX (ID INTEGER, IX INTEGER);
CREATE INDEX TYXI ON TYX (IX);
COMMIT;
CREATE VIEW IEV AS SELECT ID FROM IE1;
CREATE VIEW RV AS SELECT ID, N FROM R1;
CREATE VIEW RNV AS SELECT V FROM RN;
CREATE VIEW VCO AS SELECT ID, N FROM VB WHERE N > 5 WITH CHECK OPTION;
INSERT INTO R1 VALUES (1, 10, 'b');
INSERT INTO R1 VALUES (2, NULL, 'a');
INSERT INTO R1 VALUES (3, 30, 'c');
INSERT INTO R1 VALUES (4, 20, 'a');
INSERT INTO R1 VALUES (5, NULL, 'b');
INSERT INTO R2 VALUES (1, 3);
INSERT INTO R2 VALUES (2, 1);
INSERT INTO R2 VALUES (3, 3);
INSERT INTO R2 VALUES (4, 2);
INSERT INTO TP VALUES (1, 'a', 5);
INSERT INTO TPD (ID, D, E) VALUES (1, 1, 1);
INSERT INTO TQ VALUES (1, NULL);
INSERT INTO AT1 VALUES (1, 5, TRUE, 1.5, 1, 2);
INSERT INTO ATID (V) VALUES (1);
INSERT INTO TY VALUES (1, 7, 3, 1.5, 12.34, 1.25, DATE '2020-01-02', 'ab', 'x', 99, 4, 3.25);
INSERT INTO TT VALUES (7, '12.345');
INSERT INTO VB VALUES (1, 10);
INSERT INTO TC2 VALUES (1);
INSERT INTO TC3 VALUES (1);
INSERT INTO TYX VALUES (1, 4);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/ddlref-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/ddlref-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/ddlref-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-ddlref-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -n "${CAPTURE:-}" ]; then printf 'CAP\t%s\t%s\t%s\n' "$1" "$ev" "$fv"; return; fi
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# RECORDED: the engine answers, this server REFUSES (a clean error, never
# a wrong value). Fails the day the two agree, so the cell gets promoted.
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -n "${CAPTURE:-}" ]; then printf 'CAP\t%s\t%s\t%s\n' "$1" "$ev" "$fv"; return; fi
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS; promote the cell"; fail=1
    elif [ "${fv#*Statement failed}" = "$fv" ]; then
        echo "FAIL $1 - this server neither answers nor refuses"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: the engine answers [$ev], this server refuses)"; fi
}
# RECORDED DIVERGENCE: both sides pinned; fails when either moves
differs() { # <label> <script> <engine-output> <fc-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -n "${CAPTURE:-}" ]; then printf 'CAP\t%s\t%s\t%s\n' "$1" "$ev" "$fv"; return; fi
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - THIS SERVER MOVED: [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded divergence: engine [$ev], this server [$fv])"; fi
}
META="Statement failed, SQLSTATE = 42000|unsuccessful metadata update"
DSRC='SELECT CAST(RDB$DEFAULT_SOURCE AS VARCHAR(100)) FROM '

echo "--- 1. UPDATE / DELETE ... ORDER BY ... ROWS"
pin "1 update ... rows 1 (the hunt's member)" "UPDATE R1 SET N = 0 ROWS 1; SELECT ID, N FROM R1 ORDER BY ID; ROLLBACK;" "ID N|1 0|2 <null>|3 30|4 20|5 <null>"
pin "1 delete ... order by id desc rows 1" "DELETE FROM R1 ORDER BY ID DESC ROWS 1; SELECT ID FROM R1 ORDER BY ID; ROLLBACK;" "ID|1|2|3|4"
pin "1 delete ... rows 1 returning id" "DELETE FROM R1 ROWS 1 RETURNING ID; ROLLBACK;" "ID|1"
pin "1 delete ... rows -1: HY000 FETCH or FIRST" "DELETE FROM R1 ROWS -1; SELECT COUNT(*) FROM R1;" "Statement failed, SQLSTATE = HY000|Invalid parameter to FETCH or FIRST. Only integers >= 0 are allowed.|COUNT|5"
pin "1 update order by id desc rows 2 returning: the sorted order" "UPDATE R1 SET N = -1 ORDER BY ID DESC ROWS 2 RETURNING ID; ROLLBACK;" "ID|5|4"
pin "1 order by a nullable column: NULLs first ascending" "UPDATE R1 SET N = -1 ORDER BY N ROWS 2 RETURNING ID; ROLLBACK;" "ID|2|5"
pin "1 desc nulls first rows 2 to 3" "UPDATE R1 SET N = -1 ORDER BY N DESC NULLS FIRST ROWS 2 TO 3 RETURNING ID; ROLLBACK;" "ID|5|3"
pin "1 two keys, no rows" "UPDATE R1 SET N = -1 ORDER BY S, ID DESC RETURNING ID; ROLLBACK;" "ID|4|2|5|1|3"
pin "1 an expression key, rows 3 to 2 is none" "UPDATE R1 SET N = -1 WHERE ID > 1 ORDER BY N + ID ROWS 3 TO 2 RETURNING ID; SELECT COUNT(*) FROM R1 WHERE N = -1; ROLLBACK;" "COUNT|0"
pin "1 an expression key, rows 1 to 2" "DELETE FROM R2 ORDER BY N * 10 - ID ROWS 1 TO 2 RETURNING ID, N; ROLLBACK;" "ID N|2 1|4 2"
pin "1 rows 1 to 1" "DELETE FROM R1 ROWS 1 TO 1 RETURNING ID; ROLLBACK;" "ID|1"
pin "1 rows 0 to 2 without RETURNING: 42000 OFFSET or SKIP" "DELETE FROM R1 ROWS 0 TO 2; SELECT COUNT(*) FROM R1;" "Statement failed, SQLSTATE = 42000|Invalid parameter to OFFSET or SKIP. Only integers >= 0 are allowed.|COUNT|5"
pin "1 rows 0 to -5: the count is judged first" "DELETE FROM R1 ROWS 0 TO -5; SELECT COUNT(*) FROM R1;" "Statement failed, SQLSTATE = HY000|Invalid parameter to FETCH or FIRST. Only integers >= 0 are allowed.|COUNT|5"
pin "1 rows 0 to -1: a count of 0 opens nothing" "DELETE FROM R1 ROWS 0 TO -1; SELECT COUNT(*) FROM R1;" "COUNT|5"
pin "1 rows 1 to -1" "DELETE FROM R1 ROWS 1 TO -1; SELECT COUNT(*) FROM R1;" "Statement failed, SQLSTATE = HY000|Invalid parameter to FETCH or FIRST. Only integers >= 0 are allowed.|COUNT|5"
pin "1 rows 2 to 4" "DELETE FROM R1 ROWS 2 TO 4 RETURNING ID; ROLLBACK;" "ID|2|3|4"
pin "1 rows 3 to 99" "DELETE FROM R1 ROWS 3 TO 99 RETURNING ID; ROLLBACK;" "ID|3|4|5"
pin "1 rows 1.5 rounds to 2" "DELETE FROM R1 ROWS 1.5 RETURNING ID; ROLLBACK;" "ID|1|2"
pin "1 rows 2.5 rounds to 3" "DELETE FROM R1 ROWS 2.5 RETURNING ID; ROLLBACK;" "ID|1|2|3"
pin "1 rows 1.4 rounds to 1" "DELETE FROM R1 ROWS 1.4 RETURNING ID; ROLLBACK;" "ID|1"
pin "1 rows 2 to 1.5: (1.5 - 2) + 1 rounds to 1" "DELETE FROM R1 ROWS 2 TO 1.5 RETURNING ID; ROLLBACK;" "ID|2"
pin "1 rows null writes nothing" "DELETE FROM R1 ROWS NULL; SELECT COUNT(*) FROM R1;" "COUNT|5"
pin "1 rows null to 2 / 2 to null write nothing" "DELETE FROM R1 ROWS NULL TO 2; DELETE FROM R1 ROWS 2 TO NULL; SELECT COUNT(*) FROM R1;" "COUNT|5"
pin "1 rows '3' converts" "DELETE FROM R1 ROWS '3' RETURNING ID; ROLLBACK;" "ID|1|2|3"
pin "1 rows 'a' is 22018" "DELETE FROM R1 ROWS 'a'; SELECT COUNT(*) FROM R1;" "Statement failed, SQLSTATE = 22018|conversion error from string \"a\"|COUNT|5"
pin "1 rows 2+1" "DELETE FROM R1 ROWS 2+1 RETURNING ID; ROLLBACK;" "ID|1|2|3"
pin "1 rows 1e0" "DELETE FROM R1 ROWS 1E0 RETURNING ID; ROLLBACK;" "ID|1"
pin "1 rows past 32 bits" "DELETE FROM R1 ROWS 9999999999 RETURNING ID; ROLLBACK;" "ID|1|2|3|4|5"
pin "1 rows 0" "UPDATE R1 SET N = -1 ROWS 0 RETURNING ID; SELECT COUNT(*) FROM R1 WHERE N = -1;" "COUNT|0"
pin "1 a WHERE and rows 1" "UPDATE R1 SET N = 0 WHERE ID > 2 ROWS 1 RETURNING ID, N; ROLLBACK;" "ID N|3 0"
pin "1 a WHERE matching nothing" "DELETE FROM R1 WHERE ID = 99 ROWS 1; SELECT COUNT(*) FROM R1;" "COUNT|5"
pin "1 order by without rows: every row, sorted" "UPDATE R2 SET N = N + 1 ORDER BY N DESC, ID RETURNING ID, N; ROLLBACK;" "ID N|1 4|3 4|4 3|2 2"
pin "1 set n = n + 1 order by id rows 2, then read" "UPDATE R1 SET N = N + 1 ORDER BY ID ROWS 2; SELECT ID, N FROM R1 ORDER BY ID; ROLLBACK;" "ID N|1 11|2 <null>|3 30|4 20|5 <null>"
pin "1 a subquery IN the WHERE keeps its own ROWS" "DELETE FROM R1 WHERE ID IN (SELECT ID FROM R1 ORDER BY ID DESC ROWS 2) ROWS 1 RETURNING ID; ROLLBACK;" "ID|4"
pin "1 ordered by a text column" "DELETE FROM R1 ORDER BY S DESC, ID ROWS 2 RETURNING ID, S; ROLLBACK;" "ID S|3 c|1 b"
pin "1 R1 is whole after all of it" "SELECT ID, N, S FROM R1 ORDER BY ID;" "ID N S|1 10 b|2 <null> a|3 30 c|4 20 a|5 <null> b"
refused "1 order by after rows is -104 on the engine too, never a tail here" "UPDATE R1 SET N = 1 ROWS 1 TO 1 ORDER BY ID;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 33|-ORDER"
refused "1 order by 1: the engine's -104 invalid column position" "DELETE FROM R1 ORDER BY 1 RETURNING ID;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause"
refused "1 order by an unknown column: the engine's -206" "DELETE FROM R1 ORDER BY NOSUCH ROWS 1;" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-\"NOSUCH\"|-At line 1, column 25"
refused "1 rows (subquery) - recorded" "DELETE FROM R1 ROWS (SELECT 2 FROM RDB\$DATABASE) RETURNING ID; ROLLBACK;" "ID|1|2"
refused "1 a PLAN in a DML - recorded" "DELETE FROM R1 PLAN (R1 NATURAL) ROWS 1 RETURNING ID; ROLLBACK;" "ID|1"
refused "1 through a view - recorded" "DELETE FROM RV ORDER BY ID DESC ROWS 1 RETURNING ID; ROLLBACK;" "ID|5"
differs "1 rows 0 to 2 WITH RETURNING: the engine raises at fetch, after the header - here at execute" "DELETE FROM R1 ROWS 0 TO 2 RETURNING ID;" "ID|Statement failed, SQLSTATE = 42000|Invalid parameter to OFFSET or SKIP. Only integers >= 0 are allowed." "Statement failed, SQLSTATE = 42000|Invalid parameter to OFFSET or SKIP. Only integers >= 0 are allowed."

echo "--- 2. IF [NOT] EXISTS"
pin "2 create table if not exists over a table" "CREATE TABLE IF NOT EXISTS IE1 (Z INTEGER); COMMIT; SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'IE1';" "COUNT|2"
pin "2 create table if not exists over a VIEW: the name decides" "CREATE TABLE IF NOT EXISTS IEV (Z INTEGER); COMMIT; SELECT RDB\$VIEW_BLR IS NOT NULL FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'IEV';" "BOOL|<true>"
pin "2 create table if not exists, new" "CREATE TABLE IF NOT EXISTS TNEW (Z INTEGER); INSERT INTO TNEW VALUES (3); COMMIT; SELECT * FROM TNEW;" "Z|3"
pin "2 drop table if exists, missing" "DROP TABLE IF EXISTS NOSUCH; COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'NOSUCH';" "COUNT|0"
pin "2 drop table if exists over a VIEW runs the DROP TABLE, which fails" "DROP TABLE IF EXISTS IEV;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-DROP TABLE \"PUBLIC\".\"IEV\" failed|-SQL error code = -607|-Invalid command|-Table \"PUBLIC\".\"IEV\" does not exist"
pin "2 create sequence if not exists keeps the value" "CREATE SEQUENCE IF NOT EXISTS IES START WITH 99; CREATE GENERATOR IF NOT EXISTS IES; COMMIT; SELECT GEN_ID(IES, 0) FROM RDB\$DATABASE;" "GEN_ID|4"
pin "2 create sequence if not exists, new" "CREATE SEQUENCE IF NOT EXISTS SNEW START WITH 7; COMMIT; SELECT NEXT VALUE FOR SNEW FROM RDB\$DATABASE;" "NEXT_VALUE|7"
pin "2 create index if not exists over a name another table's index holds" "CREATE INDEX IF NOT EXISTS IEI ON IE2 (A); COMMIT; SELECT RDB\$RELATION_NAME FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'IEI';" "RDB\$RELATION_NAME|IE1"
pin "2 create unique / descending index if not exists, new" "CREATE UNIQUE INDEX IF NOT EXISTS INEW ON IE2 (A); CREATE DESCENDING INDEX IF NOT EXISTS IDSC ON IE2 (A); COMMIT; SELECT RDB\$INDEX_NAME, RDB\$UNIQUE_FLAG, RDB\$INDEX_TYPE FROM RDB\$INDICES WHERE RDB\$RELATION_NAME = 'IE2' ORDER BY 1;" "RDB\$INDEX_NAME RDB\$UNIQUE_FLAG RDB\$INDEX_TYPE|IDSC 0 1|INEW 1 0"
pin "2 create domain / exception / role if not exists over existing" "CREATE DOMAIN IF NOT EXISTS IED VARCHAR(5); CREATE EXCEPTION IF NOT EXISTS IEE 'y'; CREATE ROLE IF NOT EXISTS IER; COMMIT; SELECT RDB\$FIELD_TYPE FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'IED'; SELECT RDB\$MESSAGE FROM RDB\$EXCEPTIONS WHERE RDB\$EXCEPTION_NAME = 'IEE';" "RDB\$FIELD_TYPE|8|RDB\$MESSAGE|x"
pin "2 create domain / exception if not exists, new" "CREATE DOMAIN IF NOT EXISTS DNEW VARCHAR(5); CREATE EXCEPTION IF NOT EXISTS ENEW 'y'; COMMIT; SELECT RDB\$FIELD_TYPE, RDB\$FIELD_LENGTH FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'DNEW'; SELECT RDB\$MESSAGE FROM RDB\$EXCEPTIONS WHERE RDB\$EXCEPTION_NAME = 'ENEW';" "RDB\$FIELD_TYPE RDB\$FIELD_LENGTH|37 5|RDB\$MESSAGE|y"
pin "2 create view if not exists, existing and new" "CREATE VIEW IF NOT EXISTS IEV AS SELECT 1 X FROM RDB\$DATABASE; CREATE VIEW IF NOT EXISTS VNEW AS SELECT 1 X FROM RDB\$DATABASE; COMMIT; SELECT * FROM IEV; SELECT * FROM VNEW;" "X|1"
pin "2 alter table add if not exists, existing column" "ALTER TABLE IE1 ADD IF NOT EXISTS N VARCHAR(3); COMMIT; SELECT F.RDB\$FIELD_TYPE FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'IE1' AND RF.RDB\$FIELD_NAME = 'N';" "RDB\$FIELD_TYPE|8"
pin "2 alter table add if not exists / drop if exists" "ALTER TABLE IE1 ADD IF NOT EXISTS M INTEGER; ALTER TABLE IE1 DROP IF EXISTS NOSUCH; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'IE1' ORDER BY RDB\$FIELD_POSITION; ALTER TABLE IE1 DROP IF EXISTS M; COMMIT; SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'IE1';" "RDB\$FIELD_NAME|ID|N|M|COUNT|2"
pin "2 add constraint if not exists, twice; drop constraint if exists" "ALTER TABLE IE2 ADD CONSTRAINT IF NOT EXISTS C1 UNIQUE (A); COMMIT; ALTER TABLE IE2 ADD CONSTRAINT IF NOT EXISTS C1 UNIQUE (A); ALTER TABLE IE2 DROP CONSTRAINT IF EXISTS NOSUCH; COMMIT; SELECT RDB\$CONSTRAINT_NAME, RDB\$CONSTRAINT_TYPE FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME = 'IE2'; ALTER TABLE IE2 DROP CONSTRAINT IF EXISTS C1; COMMIT; SELECT COUNT(*) FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME = 'IE2';" "RDB\$CONSTRAINT_NAME RDB\$CONSTRAINT_TYPE|C1 UNIQUE|COUNT|0"
pin "2 drop <kind> if exists over missing names" "DROP VIEW IF EXISTS NOSUCH; DROP SEQUENCE IF EXISTS NOSUCH; DROP INDEX IF EXISTS NOSUCH; DROP DOMAIN IF EXISTS NOSUCH; DROP EXCEPTION IF EXISTS NOSUCH; DROP PROCEDURE IF EXISTS NOSUCH; DROP FUNCTION IF EXISTS NOSUCH; DROP TRIGGER IF EXISTS NOSUCH; DROP ROLE IF EXISTS NOSUCH; COMMIT; SELECT 1 FROM RDB\$DATABASE;" "CONSTANT|1"
pin "2 drop <kind> if exists over existing names" "DROP GENERATOR IF EXISTS SNEW; DROP INDEX IF EXISTS IDSC; DROP VIEW IF EXISTS VNEW; DROP DOMAIN IF EXISTS DNEW; DROP EXCEPTION IF EXISTS ENEW; COMMIT; SELECT (SELECT COUNT(*) FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'SNEW') + (SELECT COUNT(*) FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'IDSC') + (SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'VNEW') + (SELECT COUNT(*) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'DNEW') FROM RDB\$DATABASE;" "ADD|0"
pin "2 a guard with a lower-case, quoted and PUBLIC-qualified name" "CREATE TABLE IF NOT EXISTS ie1 (Z INTEGER); CREATE TABLE IF NOT EXISTS \"ie1\" (Z INTEGER); CREATE SEQUENCE IF NOT EXISTS PUBLIC.IES; COMMIT; SELECT RDB\$RELATION_NAME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME STARTING 'ie' OR RDB\$RELATION_NAME = 'IE1' ORDER BY 1;" "RDB\$RELATION_NAME|IE1|ie1"

echo "--- 3. SEQUENCES"
pin "3 create or alter sequence, new, start with 10" "CREATE OR ALTER SEQUENCE SQ2 START WITH 10; COMMIT; SELECT NEXT VALUE FOR SQ2 FROM RDB\$DATABASE;" "NEXT_VALUE|10"
refused "3 create or alter sequence, bare: -104 unexpected end - the vector is recorded" "CREATE OR ALTER SEQUENCE SQ3;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Unexpected end of command - line 1, column 29"
pin "3 create or alter sequence, new, increment only" "CREATE OR ALTER SEQUENCE SQ4 INCREMENT BY 3; COMMIT; SELECT NEXT VALUE FOR SQ4 FROM RDB\$DATABASE; SELECT NEXT VALUE FOR SQ4 FROM RDB\$DATABASE;" "NEXT_VALUE|1|NEXT_VALUE|4"
pin "3 create or alter over an existing sequence: START WITH restarts it" "SELECT NEXT VALUE FOR S9 FROM RDB\$DATABASE; CREATE OR ALTER SEQUENCE S9 START WITH 50; COMMIT; SELECT NEXT VALUE FOR S9 FROM RDB\$DATABASE; SELECT RDB\$INITIAL_VALUE FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'S9';" "NEXT_VALUE|100|NEXT_VALUE|50|RDB\$INITIAL_VALUE|100"
pin "3 create or alter over an existing sequence: a step keeps the value" "CREATE OR ALTER SEQUENCE S5 INCREMENT BY 10; COMMIT; SELECT NEXT VALUE FOR S5 FROM RDB\$DATABASE; SELECT RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'S5';" "NEXT_VALUE|13|RDB\$GENERATOR_INCREMENT|10"
pin "3 create or alter generator ... restart (to the initial value)" "CREATE OR ALTER GENERATOR S9 RESTART; COMMIT; SELECT NEXT VALUE FOR S9 FROM RDB\$DATABASE;" "NEXT_VALUE|100"
refused "3 create or alter sequence restart with: -104 at the WITH - the vector is recorded" "CREATE OR ALTER SEQUENCE S7 RESTART WITH 70;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 37|-WITH"
pin "3 gen_id step 1.7 rounds to 2" "SELECT GEN_ID(S7, 1.7) FROM RDB\$DATABASE;" "GEN_ID|2"
pin "3 gen_id step 1.2 to 1, -1.5 to -2" "SELECT GEN_ID(S7, 1.2) FROM RDB\$DATABASE; SELECT GEN_ID(S7, -1.5) FROM RDB\$DATABASE;" "GEN_ID|3|GEN_ID|1"
pin "3 gen_id step null answers NULL and does not advance" "SELECT GEN_ID(S7, NULL) FROM RDB\$DATABASE; SELECT GEN_ID(S7, CAST(NULL AS INTEGER)) FROM RDB\$DATABASE; SELECT GEN_ID(S7, 0) FROM RDB\$DATABASE;" "GEN_ID|<null>|GEN_ID|<null>|GEN_ID|1"
differs "3 gen_id step 'x' is 22018: the engine raises at fetch, after the header - here at prepare" "SELECT GEN_ID(S7, 'x') FROM RDB\$DATABASE;" "GEN_ID|Statement failed, SQLSTATE = 22018|conversion error from string \"x\"" "Statement failed, SQLSTATE = 22018|conversion error from string \"x\""
pin "3 gen_id step '3', 2e0, (1+1)" "SELECT GEN_ID(S7, '3') FROM RDB\$DATABASE; SELECT GEN_ID(S7, 2E0) FROM RDB\$DATABASE; SELECT GEN_ID(S7, (1+1)) FROM RDB\$DATABASE;" "GEN_ID|4|GEN_ID|6|GEN_ID|8"
pin "3 control: gen_id with an integer step" "SELECT GEN_ID(S8, 1) FROM RDB\$DATABASE; SELECT GEN_ID(S8, 1) FROM RDB\$DATABASE;" "GEN_ID|1|GEN_ID|2"
refused "3 next value for an undefined sequence: the BLR-offset vector - recorded" "SELECT NEXT VALUE FOR NOSUCH FROM RDB\$DATABASE;" "Statement failed, SQLSTATE = 42000|invalid request BLR at offset 38|-generator \"PUBLIC\".\"NOSUCH\" is not defined"

echo "--- 4. RDB\$DEFAULT_SOURCE AS WRITTEN; TYPED LITERAL DEFAULTS"
pin "4 a domain's source keeps its spelling (the hunt's member)" "CREATE DOMAIN DM1 AS INTEGER DeFaUlT   42; COMMIT; $DSRC RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'DM1';" "CAST|DeFaUlT 42"
pin "4 a column's source keeps its blanks" "CREATE TABLE ST (B VARCHAR(5) default   'Ab', C DATE Default Current_Date, D INTEGER default -5 not null, E TIME default LocalTime, F NUMERIC(9,2) default 1.50, G INTEGER default null, H BOOLEAN default TRUE, I TIME DEFAULT CURRENT_TIME (2)); COMMIT; $DSRC RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'ST' ORDER BY RDB\$FIELD_POSITION;" "CAST|default 'Ab'|Default Current_Date|default -5|default LocalTime|default 1.50|default null|default TRUE|DEFAULT CURRENT_TIME (2)"
pin "4 alter column set default / alter domain set default / add" "ALTER TABLE ST ALTER G SET   default 9; ALTER DOMAIN DM1 SET default     43; ALTER TABLE ST ADD Z INTEGER   default    7; COMMIT; $DSRC RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'ST' AND RDB\$FIELD_NAME IN ('G', 'Z') ORDER BY RDB\$FIELD_POSITION; $DSRC RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'DM1';" "CAST|default 9|default 7|CAST|default 43"
pin "4 typed literal defaults: create" "CREATE DOMAIN DR AS TIMESTAMP DEFAULT TIMESTAMP '2020-01-01 00:00:00'; CREATE DOMAIN DD AS DATE DEFAULT DATE '2020-02-03'; CREATE TABLE Q3 (E BOOLEAN DEFAULT FALSE, F DATE DEFAULT DATE '2021-01-01', G TIME DEFAULT TIME '10:11:12', H TIMESTAMP DEFAULT TIMESTAMP '2020-01-01 10:20:30.5', J DD, K DR); COMMIT; $DSRC RDB\$FIELDS WHERE RDB\$FIELD_NAME IN ('DR', 'DD') ORDER BY RDB\$FIELD_NAME;" "CAST|DEFAULT DATE '2020-02-03'|DEFAULT TIMESTAMP '2020-01-01 00:00:00'"
pin "4 typed literal defaults: an insert takes them" "INSERT INTO Q3 DEFAULT VALUES; SELECT * FROM Q3;" "E F G H J K|<false> 2021-01-01 10:11:12.0000 2020-01-01 10:20:30.5000 2020-02-03 2020-01-01 00:00:00.0000"
pin "4 control: a plain default still fills" "INSERT INTO ST (D) VALUES (1); SELECT B, D, F, G, H, Z FROM ST;" "B D F G H Z|Ab 1 1.50 9 <true> 7"

echo "--- 5. SET = DEFAULT; UPDATE OR INSERT WITHOUT A COLUMN LIST; RETURNING A COMPUTED COLUMN"
pin "5 set name = default returning (the hunt's member)" "UPDATE TP SET NAME = DEFAULT WHERE ID = 1 RETURNING NAME;" "NAME|dflt"
pin "5 set two columns to default: NULL where none" "UPDATE TP SET NAME = DEFAULT, N = DEFAULT WHERE ID = 1; SELECT * FROM TP;" "ID NAME N|1 dflt <null>"
pin "5 a domain's default, a column default over a domain's" "UPDATE TPD SET D = DEFAULT, E = DEFAULT, B = DEFAULT; SELECT ID, D, E, B FROM TPD;" "ID D E B|1 42 7 <true>"
refused "5 set a clock default - recorded" "UPDATE TPD SET TS = DEFAULT RETURNING TS - CURRENT_DATE; ROLLBACK;" "SUBTRACT|0"
refused "5 set an identity column to default - recorded" "UPDATE TPD SET IDN = DEFAULT; ROLLBACK;" ""
pin "5 update or insert without a column list, returning *" "UPDATE OR INSERT INTO TP VALUES (4, 'd', 1) RETURNING *;" "ID NAME N|4 d 1"
pin "5 ...a second one updates by the key" "UPDATE OR INSERT INTO TP VALUES (4, 'e', 2) RETURNING ID, NAME; SELECT * FROM TP ORDER BY ID;" "ID NAME|4 e|ID NAME N|1 dflt <null>|4 e 2"
refused "5 update or insert without a list, wrong arity: the engine's -804 - recorded" "UPDATE OR INSERT INTO TP VALUES (5, 'x');" "Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values"
pin "5 update or insert: an untyped NULL matched by MATCHING" "UPDATE OR INSERT INTO TP (ID, NAME) VALUES (7, NULL) MATCHING (NAME); UPDATE OR INSERT INTO TP (ID, NAME) VALUES (8, NULL) MATCHING (NAME); SELECT * FROM TP ORDER BY ID;" "ID NAME N|1 dflt <null>|4 e 2|8 <null> <null>"
pin "5 insert returning a computed column" "INSERT INTO TCOMP (A, B) VALUES (2, 3) RETURNING C;" "C|6"
pin "5 ...mixed with plain ones, and one computed over another" "INSERT INTO TCOMP (A, B) VALUES (2, 3) RETURNING A, C, B, D;" "A C B D|2 6 3 7"
pin "5 update returning a computed column" "UPDATE TCOMP SET A = 5 WHERE A = 2 RETURNING C, D;" "C D|15 16|15 16"
pin "5 delete returning a computed column (the row as it was)" "DELETE FROM TCOMP WHERE A = 5 RETURNING C, A;" "C A|15 5|15 5"
pin "5 returning * over a computed column" "INSERT INTO TCOMP (A, B) VALUES (4, 4) RETURNING *;" "A B C D|4 4 16 17"
refused "5 returning OLD.<computed> - recorded" "UPDATE TCOMP SET A = 1 RETURNING OLD.C; ROLLBACK;" "C|16"
pin "5 the describe of a returned computed column" "SET SQLDA_DISPLAY ON; INSERT INTO TCOMP (A, B) VALUES (1, 1) RETURNING C; ROLLBACK;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|: name: C alias: C|: table: TCOMP schema: PUBLIC owner: SYSDBA|C|1"

echo "--- 6. ALTER INDEX / COLUMN FORMS"
pin "6 alter index, lower case (the hunt's member)" "ALTER INDEX at1_n INACTIVE; COMMIT; SELECT RDB\$INDEX_INACTIVE FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'AT1_N';" "RDB\$INDEX_INACTIVE|1"
pin "6 set statistics index, lower case" "SET STATISTICS INDEX at1_q; SELECT RDB\$STATISTICS FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'AT1_Q';" "RDB\$STATISTICS|0.000000000000000"
pin "6 alter index active again" "ALTER INDEX at1_n ACTIVE; COMMIT; SELECT RDB\$INDEX_INACTIVE FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'AT1_N'; SELECT ID FROM AT1 WHERE N = 5;" "RDB\$INDEX_INACTIVE|0|ID|1"
pin "6 control: alter index in upper case" "ALTER INDEX AT1_Q INACTIVE; ALTER INDEX AT1_Q ACTIVE; COMMIT; SELECT RDB\$INDEX_INACTIVE FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'AT1_Q';" "RDB\$INDEX_INACTIVE|0"
pin "6 drop not null over a nullable column is a no-op" "ALTER TABLE AT1 ALTER COLUMN F DROP NOT NULL; COMMIT; SELECT RDB\$NULL_FLAG FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'AT1' AND RDB\$FIELD_NAME = 'F'; SELECT COUNT(*) FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME = 'AT1';" "RDB\$NULL_FLAG|<null>|COUNT|3"
pin "6 control: drop not null over a NOT NULL column" "ALTER TABLE AT1 ALTER COLUMN K DROP NOT NULL; COMMIT; SELECT RDB\$NULL_FLAG FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'AT1' AND RDB\$FIELD_NAME = 'K'; ALTER TABLE AT1 ALTER COLUMN K SET NOT NULL; COMMIT; SELECT RDB\$NULL_FLAG FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'AT1' AND RDB\$FIELD_NAME = 'K';" "RDB\$NULL_FLAG|<null>|RDB\$NULL_FLAG|1"
pin "6 identity set increment by 10" "ALTER TABLE ATID ALTER COLUMN ID SET INCREMENT BY 10; COMMIT; INSERT INTO ATID (V) VALUES (2); COMMIT; SELECT * FROM ATID ORDER BY V; SELECT G.RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS G JOIN RDB\$RELATION_FIELDS F ON F.RDB\$GENERATOR_NAME = G.RDB\$GENERATOR_NAME WHERE F.RDB\$RELATION_NAME = 'ATID';" "ID V|1 1|11 2|RDB\$GENERATOR_INCREMENT|10"
pin "6 identity set increment 5 (BY is noise)" "ALTER TABLE ATID ALTER ID SET INCREMENT 5; INSERT INTO ATID (V) VALUES (3); COMMIT; SELECT ID FROM ATID WHERE V = 3;" "ID|16"
pin "6 identity restart with 100 set increment by 3" "ALTER TABLE ATID ALTER COLUMN ID RESTART WITH 100 SET INCREMENT BY 3; COMMIT; INSERT INTO ATID (V) VALUES (4); COMMIT; SELECT ID FROM ATID WHERE V = 4;" "ID|100"
pin "6 identity set generated by default restart" "ALTER TABLE ATID ALTER COLUMN ID SET GENERATED BY DEFAULT RESTART; COMMIT; INSERT INTO ATID (ID, V) VALUES (-7, 5); INSERT INTO ATID (V) VALUES (6); COMMIT; SELECT ID, V FROM ATID WHERE V > 4 ORDER BY V;" "ID V|-7 5|1 6"
pin "6 set increment on a non-identity column" "ALTER TABLE ATID ALTER COLUMN V SET INCREMENT BY 3;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"ATID\" failed|-Column V is not an identity column"
pin "6 rename a column (the hunt's member)" "ALTER TABLE AT1 ALTER COLUMN B TO BB; ALTER TABLE AT1 ALTER N TO NN; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'AT1' ORDER BY RDB\$FIELD_POSITION; SELECT RDB\$FIELD_NAME FROM RDB\$INDEX_SEGMENTS WHERE RDB\$INDEX_NAME = 'AT1_N'; SELECT * FROM AT1;" "RDB\$FIELD_NAME|ID|NN|BB|F|K|Q|RDB\$FIELD_NAME|NN|ID NN BB F K Q|1 5 <true> 1.500000000000000 1 2"
pin "6 the renamed column reads and writes" "INSERT INTO AT1 (ID, NN, BB, K) VALUES (2, 6, FALSE, 3); SELECT ID, NN, BB FROM AT1 WHERE NN = 6; ROLLBACK;" "ID NN BB|2 6 <false>"
pin "6 rename a primary key column: the engine's JRD 218" "ALTER TABLE AT1 ALTER COLUMN ID TO ID2;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"AT1\" failed|-Cannot update index segment used by an Integrity Constraint"
pin "6 rename a missing column: DYN 176" "ALTER TABLE AT1 ALTER COLUMN NOSUCH TO X;" "Statement failed, SQLSTATE = 42S22|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"AT1\" failed|-column NOSUCH does not exist in table/view \"PUBLIC\".\"AT1\""
pin "6 rename onto a held name: DYN 205" "ALTER TABLE AT1 ALTER COLUMN NN TO ID;" "Statement failed, SQLSTATE = 42S21|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"AT1\" failed|-Cannot rename column NN to ID. A column with that name already exists in table \"PUBLIC\".\"AT1\"."
pin "6 rename a NOT NULL column: its constraint link follows" "ALTER TABLE RN ALTER COLUMN K TO K2; COMMIT; SELECT C.RDB\$TRIGGER_NAME FROM RDB\$CHECK_CONSTRAINTS C JOIN RDB\$RELATION_CONSTRAINTS R ON R.RDB\$CONSTRAINT_NAME = C.RDB\$CONSTRAINT_NAME WHERE R.RDB\$RELATION_NAME = 'RN' AND R.RDB\$CONSTRAINT_TYPE = 'NOT NULL' ORDER BY 1;" "RDB\$TRIGGER_NAME|ID|K2"
pin "6 rename a column a view reads: DYN 206" "ALTER TABLE RN ALTER COLUMN V TO V2;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"RN\" failed|-Column \"V\" from table \"PUBLIC\".\"RN\" is referenced in \"PUBLIC\".\"RNV\""
pin "6 rename a column a CHECK reads: DYN 206" "ALTER TABLE RN ALTER COLUMN W TO W2;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"RN\" failed|-Column \"W\" from table \"PUBLIC\".\"RN\" is referenced in \"PUBLIC\".\"CHECK_1\""
pin "6 rename a column a computed column reads: DYN 206" "ALTER TABLE RN ALTER COLUMN X TO X2;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"RN\" failed|-Column \"X\" from table \"PUBLIC\".\"RN\" is referenced in \"PUBLIC\".\"RDB\$35\""
pin "6 rename a UNIQUE column: JRD 218" "ALTER TABLE RN ALTER COLUMN U TO U2;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"RN\" failed|-Cannot update index segment used by an Integrity Constraint"
pin "6 rename to a quoted name, and the computed column itself" "ALTER TABLE RN ALTER COLUMN Q TO \"q2\"; ALTER TABLE RN ALTER COLUMN C TO C2; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'RN' ORDER BY RDB\$FIELD_POSITION; SELECT RDB\$FIELD_NAME FROM RDB\$INDEX_SEGMENTS WHERE RDB\$INDEX_NAME = 'RNQ'; INSERT INTO RN (ID, K2, \"q2\", X) VALUES (1, 2, 3, 4); SELECT * FROM RN;" "RDB\$FIELD_NAME|ID|K2|V|W|X|C2|U|q2|RDB\$FIELD_NAME|q2|ID K2 V W X C2 U q2|1 2 <null> <null> 4 5 <null> 3"
pin "6 alter type integer to double precision" "ALTER TABLE TY ALTER I TYPE DOUBLE PRECISION; ALTER TABLE TY ALTER S TYPE DOUBLE PRECISION; ALTER TABLE TY ALTER FL TYPE DOUBLE PRECISION; ALTER TABLE TY ALTER NN TYPE DOUBLE PRECISION; COMMIT; SELECT I, S, FL, NN FROM TY;" "I S FL NN|7.000000000000000 3.000000000000000 1.500000000000000 3.250000000000000"
pin "6 alter type numeric(10,2) to numeric(18,4) (the hunt's member)" "ALTER TABLE TY ALTER COLUMN AMT TYPE NUMERIC(18,4); ALTER TABLE TY ALTER N52 TYPE NUMERIC(9,4); ALTER TABLE TY ALTER ID TYPE NUMERIC(9,3); COMMIT; SELECT ID, AMT, N52 FROM TY;" "ID AMT N52|1.000 12.3400 1.2500"
pin "6 alter type date to timestamp" "ALTER TABLE TY ALTER DT TYPE TIMESTAMP; COMMIT; SELECT DT FROM TY;" "DT|2020-01-02 00:00:00.0000"
pin "6 alter type varchar(5) to char(6), char(3) to varchar(4)" "ALTER TABLE TY ALTER V TYPE CHAR(6); ALTER TABLE TY ALTER C TYPE VARCHAR(4); COMMIT; SELECT '[' || V || ']', '[' || C || ']', CHAR_LENGTH(C) FROM TY;" "CONCATENATION CONCATENATION CHAR_LENGTH|[ab ] [x ] 3"
pin "6 the retyped catalog rows" "SELECT RF.RDB\$FIELD_NAME, F.RDB\$FIELD_TYPE, F.RDB\$FIELD_LENGTH, F.RDB\$FIELD_SCALE, F.RDB\$FIELD_SUB_TYPE, F.RDB\$FIELD_PRECISION, F.RDB\$CHARACTER_LENGTH FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'TY' ORDER BY RF.RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME RDB\$FIELD_TYPE RDB\$FIELD_LENGTH RDB\$FIELD_SCALE RDB\$FIELD_SUB_TYPE RDB\$FIELD_PRECISION RDB\$CHARACTER_LENGTH|ID 8 4 -3 1 9 <null>|I 27 8 0 <null> <null> <null>|S 27 8 0 <null> <null> <null>|FL 27 8 0 <null> <null> <null>|AMT 16 8 -4 1 18 <null>|N52 8 4 -4 1 9 <null>|DT 35 8 0 <null> <null> <null>|V 14 6 0 0 <null> 6|C 37 4 0 0 <null> 4|BI 16 8 0 0 0 <null>|IX 8 4 0 0 0 <null>|NN 27 8 0 <null> <null> <null>"
pin "6 rows written after the retype, and an update of an old row" "INSERT INTO TY VALUES (2, 8, 4, 2.5, 1.5, 2.5, TIMESTAMP '2021-01-01 10:00:00', 'q', 'yy', 1, 5, 1.5); UPDATE TY SET V = 'zz' WHERE ID = 1; SELECT * FROM TY ORDER BY ID;" "ID I S FL AMT N52 DT V C BI IX NN|1.000 7.000000000000000 3.000000000000000 1.500000000000000 12.3400 1.2500 2020-01-02 00:00:00.0000 zz x 99 4 3.250000000000000|2.000 8.000000000000000 4.000000000000000 2.500000000000000 1.5000 2.5000 2021-01-01 10:00:00.0000 q yy 1 5 1.500000000000000"
pin "6 varchar widening: RDB\$FIELD_LENGTH is the byte length" "ALTER TABLE TT ALTER S TYPE VARCHAR(12); COMMIT; SELECT F.RDB\$FIELD_LENGTH, F.RDB\$CHARACTER_LENGTH FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'TT' AND RF.RDB\$FIELD_NAME = 'S';" "RDB\$FIELD_LENGTH RDB\$CHARACTER_LENGTH|12 12"
refused "6 bigint to double: the engine refuses too - the vector is recorded" "ALTER TABLE TY ALTER BI TYPE DOUBLE PRECISION; COMMIT; SELECT BI FROM TY ORDER BY ID;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"TY\" failed|-Cannot change datatype for \"BI\". Conversion from base type BIGINT to DOUBLE PRECISION is not supported.|BI|99|1"
refused "6 an indexed integer to double - recorded (the index keys would change)" "ALTER TABLE TYX ALTER IX TYPE DOUBLE PRECISION; COMMIT; SELECT IX FROM TYX;" "IX|4.000000000000000"
refused "6 add a column with an inline CHECK - recorded" "ALTER TABLE TC3 ADD W INTEGER CHECK (W > 0); COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TC3' ORDER BY RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME|ID|W"
refused "6 add a column with an inline UNIQUE - recorded" "ALTER TABLE TC3 ADD U VARCHAR(5) UNIQUE; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TC3' ORDER BY RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME|ID|W|U"
pin "6 control: add ... default 7 not null over a row" "ALTER TABLE TC2 ADD X INTEGER DEFAULT 7 NOT NULL; COMMIT; SELECT * FROM TC2;" "ID X|1 7"

echo "--- 7. CAST TO A DOMAIN"
pin "7 cast to a numeric domain" "SELECT CAST('1.234' AS D_NUM) FROM RDB\$DATABASE;" "CAST|1.23"
pin "7 cast to a text domain: the 22001 truncation" "SELECT CAST('abcdef' AS D_VC) FROM RDB\$DATABASE;" "CAST|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 5, actual 6"
pin "7 cast to a text domain" "SELECT CAST('abc' AS D_VC) FROM RDB\$DATABASE;" "CAST|abc"
pin "7 cast as type of a checked domain: no validation" "SELECT CAST(5 AS TYPE OF D_POS) FROM RDB\$DATABASE; SELECT CAST(-5 AS TYPE OF D_POS) FROM RDB\$DATABASE; SELECT CAST(NULL AS TYPE OF D_NN) FROM RDB\$DATABASE;" "CAST|5|CAST|-5|CAST|<null>"
pin "7 casts over columns" "SELECT CAST(A AS D_INT) + 1, CAST(S AS D_DEC), CAST(S AS D_CH) FROM TT;" "ADD CAST CAST|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 4, actual 6"
pin "7 timestamp, double, boolean domains" "SELECT CAST('2020-01-02 03:04:05' AS D_TS), CAST(A AS D_DBL), CAST('true' AS D_BOOL) FROM TT;" "CAST CAST CAST|2020-01-02 03:04:05.0000 7.000000000000000 <true>"
pin "7 nested" "SELECT CAST(CAST(A AS D_INT) AS D_NUM) FROM TT;" "CAST|7.00"
pin "7 in DML" "UPDATE TT SET A = CAST(9 AS D_INT) RETURNING A; INSERT INTO TT (A, S) VALUES (CAST('3' AS D_INT), CAST(1.5 AS D_VC)) RETURNING A, S; ROLLBACK;" "A|9|A S|3 1.5"
pin "7 the describe" "SET SQLDA_DISPLAY ON; SELECT CAST(A AS D_NUM), CAST(S AS D_VC) FROM TT;" "INPUT message field count: 0|OUTPUT message field count: 2|01: sqltype: 496 LONG Nullable scale: -2 subtype: 1 len: 4|: name: CAST alias: CAST|: table: schema: owner:|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 4 SYSTEM.UTF8|: name: CAST alias: CAST|: table: schema: owner:|CAST CAST|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 5, actual 6"
refused "7 cast to a CHECKed domain (the hunt's member) - recorded" "SELECT CAST(5 AS D_POS) FROM RDB\$DATABASE;" "CAST|5"
refused "7 cast to a CHECKed domain, failing - recorded" "SELECT CAST(-5 AS D_POS) FROM RDB\$DATABASE;" "CAST|Statement failed, SQLSTATE = 42000|validation error for CAST, value \"-5\""
refused "7 cast NULL to a NOT NULL domain - recorded" "SELECT CAST(NULL AS D_NN) FROM RDB\$DATABASE;" "CAST|Statement failed, SQLSTATE = 42000|validation error for CAST, value \"*** null ***\""
refused "7 cast to a collated domain - recorded" "SELECT CAST('A' AS D_CI) FROM RDB\$DATABASE;" "CAST|A"
refused "7 a domain column with a COLLATE override - recorded" "CREATE TABLE Q4 (V D_VC COLLATE UNICODE_CI); COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'Q4';" "COUNT|1"

echo "--- 8. RECORDED: STILL REFUSED"
refused "8 insert under an expression index" "INSERT INTO EX1 VALUES ('abc'); SELECT * FROM EX1; ROLLBACK;" "B|abc"
refused "8 insert under a partial unique index" "INSERT INTO EX3 VALUES (1); SELECT * FROM EX3; ROLLBACK;" "A|1"
refused "8 insert under a DECFLOAT unique index" "INSERT INTO DFC VALUES (1.5); SELECT * FROM DFC; ROLLBACK;" "X|1.5"
refused "8 insert under a TIME WITH TIME ZONE index" "INSERT INTO X3 VALUES (TIME '10:00:00 UTC'); SELECT COUNT(*) FROM X3; ROLLBACK;" "COUNT|1"
refused "8 computed by over a numeric" "CREATE TABLE C1 (X NUMERIC(10,2), Y COMPUTED BY (X * 2)); COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'C1';" "COUNT|1"
refused "8 computed by a concatenation" "CREATE TABLE C4 (X INTEGER, W COMPUTED BY (X || 'a')); COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'C4';" "COUNT|1"
refused "8 computed by a function" "CREATE TABLE C13 (X INTEGER, W COMPUTED BY (COALESCE(X, 0))); COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'C13';" "COUNT|1"
refused "8 generated always as over another generated column" "CREATE TABLE C2 (X INTEGER, Y GENERATED ALWAYS AS (X * 2), Z GENERATED ALWAYS AS (Y + 1)); COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'C2';" "COUNT|1"
differs "8 RETURNING through a WITH CHECK OPTION view: the engine's 0/0 - recorded" "INSERT INTO VCO VALUES (2, 20) RETURNING ID, N; UPDATE VCO SET N = 12 WHERE ID = 1 RETURNING ID, N; SELECT * FROM VB ORDER BY ID; ROLLBACK;" "ID N|0 0|ID N|1 12|2 20" "ID N|2 20|ID N|1 12|ID N|1 12|2 20"

echo "--- 10. THE REVIEW OF c697f49"
# a rescale that keeps the storage word: the value is read through the
# NEW word, and one that no longer fits it raises 22003 at the read (the
# declared precision bounds nothing) - here it wrapped
pin "10 rescale in the same word: the ALTERs are taken" "CREATE TABLE OV (ID INTEGER, S SMALLINT, I INTEGER, A NUMERIC(3,1), C INTEGER, OK SMALLINT); COMMIT; INSERT INTO OV VALUES (1, 32000, 2000000000, 3276.7, 30000000, 300); INSERT INTO OV VALUES (2, 3, 4, 1.5, 5, 7); COMMIT; ALTER TABLE OV ALTER S TYPE NUMERIC(4,2); ALTER TABLE OV ALTER I TYPE NUMERIC(9,3); ALTER TABLE OV ALTER A TYPE NUMERIC(4,2); ALTER TABLE OV ALTER C TYPE NUMERIC(9,2); ALTER TABLE OV ALTER OK TYPE NUMERIC(4,2); COMMIT; SELECT COUNT(*) FROM OV;" "COUNT|2"
pin "10 smallint 32000 -> numeric(4,2): 22003 at the read" "SELECT ID, S FROM OV;" "ID S|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "10 integer 2000000000 -> numeric(9,3): 22003" "SELECT ID, I FROM OV;" "ID I|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "10 numeric(3,1) 3276.7 -> numeric(4,2): 22003" "SELECT ID, A FROM OV;" "ID A|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "10 integer 30000000 -> numeric(9,2): 22003, SUM too" "SELECT ID, C FROM OV; SELECT SUM(C) FROM OV;" "ID C|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|SUM|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "10 the rows that fit read, and a filter that skips the other" "SELECT ID, S, I, A, C FROM OV WHERE ID = 2; SELECT ID, OK FROM OV ORDER BY ID;" "ID S I A C|2 3.00 4.000 1.50 5.00|ID OK|1 300.00|2 7.00"
# a quoted name that is not its own fold: this server's generator
# lookups fold, so CREATE OR ALTER / the guard over one are refused -
# S7's namesake is never restarted
pin "10 a quoted sequence name: the setup" "CREATE SEQUENCE QS7; COMMIT; SELECT NEXT VALUE FOR QS7 FROM RDB\$DATABASE;" "NEXT_VALUE|1"
refused "10 create or alter sequence \"qs7\" over QS7 - recorded" "CREATE OR ALTER SEQUENCE \"qs7\" START WITH 50;" ""
refused "10 create sequence if not exists \"qs7\" over QS7 - recorded" "CREATE SEQUENCE IF NOT EXISTS \"qs7\" START WITH 7;" ""
pin "10 ...and QS7 kept its value" "SELECT NEXT VALUE FOR QS7 FROM RDB\$DATABASE;" "NEXT_VALUE|2"
# the guard only where the grammar has it: CREATE ... IF NOT EXISTS and
# DROP ... IF EXISTS
refused "10 drop domain if not exists: the engine's -104 - the vector is recorded" "DROP DOMAIN IF NOT EXISTS IED;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 16|-NOT"
refused "10 create domain if exists - the vector is recorded" "CREATE DOMAIN IF EXISTS QD2 INTEGER;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 18|-EXISTS"
refused "10 alter domain if exists - the vector is recorded" "ALTER DOMAIN IF EXISTS IED SET DEFAULT 1;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 17|-EXISTS"
refused "10 drop exception if not exists - the vector is recorded" "DROP EXCEPTION IF NOT EXISTS IEE;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 19|-NOT"
refused "10 create exception if exists - the vector is recorded" "CREATE EXCEPTION IF EXISTS QE2 'y';" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 21|-EXISTS"
refused "10 create role if exists - the vector is recorded" "CREATE ROLE IF EXISTS QR9;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 16|-EXISTS"
refused "10 drop role if not exists - the vector is recorded" "DROP ROLE IF NOT EXISTS IER;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 14|-NOT"
refused "10 an exception name of two words - the vector is recorded" "CREATE EXCEPTION QE3 X 'y';" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 22|-X"
pin "10 ...and none of them wrote the catalog" "COMMIT; SELECT CAST(RDB\$DEFAULT_SOURCE AS VARCHAR(20)) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'IED'; SELECT COUNT(*) FROM RDB\$EXCEPTIONS WHERE TRIM(RDB\$EXCEPTION_NAME) CONTAINING ' ' OR RDB\$EXCEPTION_NAME STARTING 'QE'; SELECT COUNT(*) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'QD2'; SELECT COUNT(*) FROM RDB\$ROLES WHERE RDB\$ROLE_NAME IN ('QR9', 'IER');" "CAST|<null>|COUNT|0|COUNT|0|COUNT|1"
# ALTER TABLE ... IF [NOT] EXISTS on no table: 42S02 whatever the guard
pin "10 alter table <missing> drop if exists: 42S02" "ALTER TABLE NOSUCH DROP IF EXISTS C;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"NOSUCH\" failed|-SQL error code = -607|-Invalid command|-Table \"PUBLIC\".\"NOSUCH\" does not exist"
pin "10 alter table <view> drop if exists: 42S02" "ALTER TABLE IEV DROP IF EXISTS ZZ;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"IEV\" failed|-SQL error code = -607|-Invalid command|-Table \"PUBLIC\".\"IEV\" does not exist"
pin "10 alter table <missing> add if not exists: 42S02" "ALTER TABLE NOSUCH ADD IF NOT EXISTS C INTEGER;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"NOSUCH\" failed|-SQL error code = -607|-Invalid command|-Table \"PUBLIC\".\"NOSUCH\" does not exist"
refused "10 alter table <missing> drop column if exists - the vector is recorded" "ALTER TABLE NOSUCH DROP COLUMN IF EXISTS C;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"NOSUCH\" failed|-SQL error code = -607|-Invalid command|-Table \"PUBLIC\".\"NOSUCH\" does not exist"
pin "10 alter table <missing> drop constraint if exists: 42S02" "ALTER TABLE NOSUCH DROP CONSTRAINT IF EXISTS CC;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"NOSUCH\" failed|-SQL error code = -607|-Invalid command|-Table \"PUBLIC\".\"NOSUCH\" does not exist"
# a step is a signed_long_integer: -2147483648 is -104
pin "10 identity with a step: the setup" "CREATE TABLE QT4 (ID BIGINT GENERATED BY DEFAULT AS IDENTITY, V INTEGER); COMMIT; SELECT COUNT(*) FROM QT4;" "COUNT|0"
refused "10 identity set increment by -2147483648 - the vector is recorded" "ALTER TABLE QT4 ALTER ID SET INCREMENT BY -2147483648;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 44|-2147483648"
refused "10 identity restart + set increment by -2147483648 - the vector is recorded" "ALTER TABLE QT4 ALTER ID RESTART WITH 3 SET INCREMENT BY -2147483648;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 59|-2147483648"
refused "10 create or alter sequence increment by -2147483648 - the vector is recorded" "CREATE OR ALTER SEQUENCE QS2 INCREMENT BY -2147483648;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 44|-2147483648"
refused "10 create sequence increment by -2147483648 - the vector is recorded" "CREATE SEQUENCE QS3 INCREMENT BY -2147483648;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 35|-2147483648"
refused "10 alter sequence increment by -2147483648 - the vector is recorded" "ALTER SEQUENCE QS7 INCREMENT BY -2147483648;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 34|-2147483648"
refused "10 an identity column declared with -2147483648 - the vector is recorded" "CREATE TABLE QT5 (ID BIGINT GENERATED BY DEFAULT AS IDENTITY (INCREMENT BY -2147483648));" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 77|-2147483648"
pin "10 ...none took, and -2147483647 is a step" "COMMIT; INSERT INTO QT4 (V) VALUES (1) RETURNING ID; CREATE OR ALTER SEQUENCE QS4 INCREMENT BY -2147483647; COMMIT; SELECT RDB\$GENERATOR_NAME, RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_INCREMENT < -2000000000 OR RDB\$GENERATOR_NAME IN ('QS2', 'QS3') ORDER BY 1; ROLLBACK;" "ID|1|RDB\$GENERATOR_NAME RDB\$GENERATOR_INCREMENT|QS4 -2147483647"

echo "--- 11. THE REVIEW OF THE MERGED fc/integ4"
# an UPDATE of a row a rescale pushed out of its storage word: the engine
# MOV_moves the whole old record into the new format before any SET, so
# every write of that row raises 22003, whichever column it sets (here it
# stored NULL in the overflowing column and committed it); a DELETE does
# not convert, and its RETURNING raises only where it presents the column
pin "11 overflowing rescale: the setup" "CREATE TABLE W76 (ID INTEGER, A SMALLINT, B INTEGER); COMMIT; INSERT INTO W76 VALUES (1, 32000, 2000000000); INSERT INTO W76 VALUES (2, 300, 7); COMMIT; ALTER TABLE W76 ALTER A TYPE NUMERIC(4,2); COMMIT; SELECT COUNT(*) FROM W76;" "COUNT|2"
pin "11 update another column of the overflowing row: 22003" "UPDATE W76 SET B = 5 WHERE ID = 1;" "Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "11 set the overflowing column itself, or NULL: 22003" "UPDATE W76 SET A = 1 WHERE ID = 1; UPDATE W76 SET A = NULL WHERE ID = 1;" "Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "11 a statement that reaches the row among others: 22003, nothing written" "UPDATE W76 SET ID = ID WHERE B > 0; SELECT ID, B FROM W76 ORDER BY ID;" "Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|ID B|1 2000000000|2 7"
pin "11 update or insert and merge matching the row: 22003" "UPDATE OR INSERT INTO W76 (ID, B) VALUES (1, 9) MATCHING (ID); MERGE INTO W76 T USING (SELECT 1 X FROM RDB\$DATABASE) S ON T.ID = S.X WHEN MATCHED THEN UPDATE SET B = 10;" "Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin "11 a PSQL update of the row: 22003" "SET TERM ^; EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN UPDATE W76 SET B = 11 WHERE ID = 1; R = ROW_COUNT; SUSPEND; END^ SET TERM ;^" "R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|-At block line: 1, col: 44"
pin "11 the row that fits updates, the other keeps its values" "UPDATE W76 SET B = 6 WHERE ID = 2; COMMIT; SELECT ID, B FROM W76 ORDER BY ID;" "ID B|1 2000000000|2 6"
pin "11 delete returning the id deletes; returning the column raises" "DELETE FROM W76 WHERE ID = 1 RETURNING ID; ROLLBACK; DELETE FROM W76 WHERE ID = 1 RETURNING A; ROLLBACK; SELECT COUNT(*) FROM W76;" "ID|1|A|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|COUNT|2"
pin "11 integer 2000000000 -> numeric(9,3), update by id: 22003" "ALTER TABLE W76 ALTER B TYPE NUMERIC(9,3); COMMIT; UPDATE W76 SET ID = 11 WHERE ID = 1; SELECT ID FROM W76 ORDER BY ID;" "Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|ID|1|2"
# a rolled-back ALTER leaves a DEAD head on the catalog row; the next
# patch of that row starts from the version the catalog sees (here it
# patched the dead head and committed the rolled-back change with it)
pin "11 rolled-back DDL: the setup" "CREATE TABLE W47 (ID INTEGER NOT NULL, A INTEGER, B VARCHAR(10) DEFAULT 'd'); COMMIT; INSERT INTO W47 VALUES (1, 1, 'x'); COMMIT; SELECT COUNT(*) FROM W47;" "COUNT|1"
pin "11 a rolled-back rename, then SET DEFAULT: the column stays B" "SET AUTODDL OFF; ALTER TABLE W47 ALTER COLUMN B TO BB; ROLLBACK; ALTER TABLE W47 ALTER B SET DEFAULT 'z2'; COMMIT; SELECT RDB\$FIELD_NAME, RDB\$FIELD_POSITION, CAST(RDB\$DEFAULT_SOURCE AS VARCHAR(20)) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'W47' ORDER BY RDB\$FIELD_POSITION; SELECT * FROM W47;" "RDB\$FIELD_NAME RDB\$FIELD_POSITION CAST|ID 0 <null>|A 1 <null>|B 2 DEFAULT 'z2'|ID A B|1 1 x"
pin "11 a rolled-back POSITION, then SET DEFAULT on its neighbour" "SET AUTODDL OFF; ALTER TABLE W47 ALTER COLUMN B POSITION 1; ROLLBACK; ALTER TABLE W47 ALTER A SET DEFAULT 1; COMMIT; SELECT RDB\$FIELD_NAME, RDB\$FIELD_POSITION, CAST(RDB\$DEFAULT_SOURCE AS VARCHAR(20)) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'W47' ORDER BY RDB\$FIELD_POSITION; UPDATE W47 SET B = DEFAULT; SELECT * FROM W47; ROLLBACK;" "RDB\$FIELD_NAME RDB\$FIELD_POSITION CAST|ID 0 <null>|A 1 DEFAULT 1|B 2 DEFAULT 'z2'|ID A B|1 1 z2"
pin "11 rolled-back rename / type / drop default / not null, each followed by another patch" "SET AUTODDL OFF; ALTER TABLE W47 ALTER COLUMN B TO BB; ROLLBACK; ALTER TABLE W47 ALTER B SET NOT NULL; COMMIT; ALTER TABLE W47 ALTER A TYPE BIGINT; ROLLBACK; ALTER TABLE W47 ALTER A SET DEFAULT 3; COMMIT; ALTER TABLE W47 ALTER A DROP DEFAULT; ROLLBACK; ALTER TABLE W47 ALTER A TO AA; COMMIT; ALTER TABLE W47 ALTER AA SET NOT NULL; ROLLBACK; ALTER TABLE W47 ALTER AA POSITION 3; COMMIT; SELECT RF.RDB\$FIELD_NAME, RF.RDB\$FIELD_POSITION, RF.RDB\$NULL_FLAG, CAST(RF.RDB\$DEFAULT_SOURCE AS VARCHAR(20)), F.RDB\$FIELD_TYPE FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'W47' ORDER BY RF.RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME RDB\$FIELD_POSITION RDB\$NULL_FLAG CAST RDB\$FIELD_TYPE|ID 0 1 <null> 8|B 1 1 DEFAULT 'z2' 37|AA 2 <null> DEFAULT 3 8"
pin "11 a rolled-back ALTER DOMAIN, then a rename of it; a rolled-back INACTIVE" "CREATE DOMAIN W5D INTEGER; CREATE INDEX W47I ON W47 (ID); COMMIT; SET AUTODDL OFF; ALTER DOMAIN W5D SET DEFAULT 5; ROLLBACK; ALTER DOMAIN W5D TO W5D2; COMMIT; ALTER INDEX W47I INACTIVE; ROLLBACK; ALTER INDEX W47I INACTIVE; ALTER INDEX W47I ACTIVE; COMMIT; SELECT RDB\$FIELD_NAME, CAST(RDB\$DEFAULT_SOURCE AS VARCHAR(20)) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME STARTING 'W5D'; SELECT RDB\$INDEX_INACTIVE FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'W47I'; SELECT ID FROM W47 WHERE ID = 1;" "RDB\$FIELD_NAME CAST|W5D2 <null>|RDB\$INDEX_INACTIVE|0|ID|1"
# an INACTIVE index keeps its slot in irt_drop with irt_descending (the
# engine's setDrop clears only the enforcing flags), and no retrieval
# reads through it (here the flags were zeroed and the dropped DESC tree
# was read as an ascending one: `where a = 7` found nothing)
pin "11 desc index inactive then active: the lookups find the rows" "CREATE TABLE W20 (ID INTEGER NOT NULL, A INTEGER); COMMIT; INSERT INTO W20 VALUES (1, 5); INSERT INTO W20 VALUES (2, NULL); INSERT INTO W20 VALUES (3, 7); COMMIT; CREATE DESC INDEX W34 ON W20 (A); COMMIT; alter index w34 inactive; COMMIT; alter index w34 active; COMMIT; SELECT ID FROM W20 WHERE A = 7; SELECT ID FROM W20 WHERE A > 6; SELECT ID FROM W20 WHERE A < 6; SELECT ID FROM W20 WHERE A = 5; SELECT ID FROM W20 WHERE A IS NULL;" "ID|3|ID|3|ID|1|ID|1|ID|2"
pin "11 inactive again, an ascending index beside it, then dropped" "ALTER INDEX W34 INACTIVE; COMMIT; SELECT ID FROM W20 WHERE A = 7; CREATE INDEX W36 ON W20 (A); COMMIT; SELECT ID FROM W20 WHERE A = 7; INSERT INTO W20 VALUES (4, 7); COMMIT; SELECT ID FROM W20 WHERE A = 7 ORDER BY ID; DROP INDEX W34; COMMIT; SELECT ID FROM W20 WHERE A = 7 ORDER BY ID; SELECT ID FROM W20 WHERE A > 5 ORDER BY A DESC, ID;" "ID|3|ID|3|ID|3|4|ID|3|4|ID|3|4"
pin "11 a unique desc index inactive: not enforced, then active again" "CREATE UNIQUE DESC INDEX W37 ON W20 (ID); COMMIT; ALTER INDEX W37 INACTIVE; COMMIT; INSERT INTO W20 VALUES (4, 1); SELECT COUNT(*) FROM W20 WHERE ID = 4; ROLLBACK; ALTER INDEX W37 ACTIVE; COMMIT; SELECT ID FROM W20 WHERE ID = 3; SELECT ID FROM W20 WHERE ID >= 3 ORDER BY ID DESC; INSERT INTO W20 VALUES (3, 0);" "COUNT|2|ID|3|ID|4|3|Statement failed, SQLSTATE = 23000|attempt to store duplicate value (visible to active transactions) in unique index \"PUBLIC\".\"W37\"|-Problematic key value is (\"ID\" = 3)"
# an index build keys the version the catalog sees: a rolled-back
# duplicate is not a duplicate (here it refused "duplicate key")
pin "11 create unique index over a rolled-back duplicate" "CREATE TABLE W21 (ID INTEGER); COMMIT; INSERT INTO W21 VALUES (1); COMMIT; INSERT INTO W21 VALUES (1); ROLLBACK; UPDATE W21 SET ID = 2; ROLLBACK; CREATE UNIQUE INDEX W21U ON W21 (ID); COMMIT; SELECT ID FROM W21 WHERE ID = 1; SELECT COUNT(*) FROM W21 WHERE ID = 2;" "ID|1|COUNT|0"
# DROP DEFAULT drops the column's OWN default only: DYN 229 / DYN 230
pin "11 drop default: the setup" "CREATE DOMAIN W74D INTEGER DEFAULT 42; CREATE TABLE W74 (ID INTEGER, C W74D, A INTEGER, E INTEGER DEFAULT 3, G W74D DEFAULT 9); COMMIT; SELECT COUNT(*) FROM W74;" "COUNT|0"
pin "11 drop default of a domain's default: DYN 230" "ALTER TABLE W74 ALTER C DROP DEFAULT;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"W74\" failed|-Local column \"C\" default belongs to domain \"PUBLIC\".\"W74D\""
pin "11 drop default of no default: DYN 229, AUTODDL off too" "ALTER TABLE W74 ALTER A DROP DEFAULT; SET AUTODDL OFF; ALTER TABLE W74 ALTER ID DROP DEFAULT; COMMIT;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"W74\" failed|-Local column A doesn't have a default|Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"W74\" failed|-Local column ID doesn't have a default"
pin "11 drop a local default, twice" "ALTER TABLE W74 ALTER E DROP DEFAULT; ALTER TABLE W74 ALTER E DROP DEFAULT; ALTER TABLE W74 ALTER G DROP DEFAULT; ALTER TABLE W74 ALTER G DROP DEFAULT; COMMIT; INSERT INTO W74 (ID) VALUES (1); SELECT * FROM W74; ROLLBACK;" "Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"W74\" failed|-Local column E doesn't have a default|Statement failed, SQLSTATE = 42000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"W74\" failed|-Local column \"G\" default belongs to domain \"PUBLIC\".\"W74D\"|ID C A E G|1 42 <null> <null> 42"

echo "--- 9. THE FILE AFTER ALL OF IT"
gf=$(gfix -v -full -user "$U" -pas "$P" "$FC" 2>&1)
ran=$((ran + 1))
if [ -n "${CAPTURE:-}" ]; then :
elif [ -z "$gf" ]; then echo "OK   9 gfix -v -full clean on fc's file"; else echo "FAIL 9 gfix: $gf"; fail=1; fi
# the ENGINE opens fc's file (the server is stopped first): every table
# the cells above altered, retyped, renamed or filled reads as it reads
# on the engine's own
kill $srv 2>/dev/null; wait $srv 2>/dev/null
FILEQ="SELECT * FROM TY ORDER BY ID; SELECT * FROM AT1; SELECT * FROM RN; SELECT * FROM ATID ORDER BY V; SELECT * FROM Q3; SELECT B, D, F, G, H, Z FROM ST; SELECT * FROM TP ORDER BY ID; SELECT * FROM TCOMP ORDER BY A; SELECT * FROM TC2; SELECT * FROM R1 ORDER BY ID; SELECT GEN_ID(S5, 0), GEN_ID(S7, 0), GEN_ID(S9, 0), GEN_ID(SQ2, 0), GEN_ID(IES, 0) FROM RDB\$DATABASE; INSERT INTO Q3 DEFAULT VALUES; SELECT COUNT(*) FROM Q3 WHERE F = DATE '2021-01-01'; INSERT INTO ATID (V) VALUES (9); SELECT ID FROM ATID WHERE V = 9; ROLLBACK;"
ran=$((ran + 1))
ev=$(sess "127.0.0.1/$REAL:$ENG" "$FILEQ"); fv=$(sess "127.0.0.1/$REAL:$FC" "$FILEQ")
if [ -n "${CAPTURE:-}" ]; then printf 'CAP\t%s\t%s\t%s\n' "9 file" "$ev" "$fv"
elif [ "$ev" != "ID I S FL AMT N52 DT V C BI IX NN|1.000 7.000000000000000 3.000000000000000 1.500000000000000 12.3400 1.2500 2020-01-02 00:00:00.0000 zz x 99 4 3.250000000000000|2.000 8.000000000000000 4.000000000000000 2.500000000000000 1.5000 2.5000 2021-01-01 10:00:00.0000 q yy 1 5 1.500000000000000|ID NN BB F K Q|1 5 <true> 1.500000000000000 1 2|ID K2 V W X C2 U q2|1 2 <null> <null> 4 5 <null> 3|ID V|1 1|11 2|16 3|100 4|-7 5|1 6|E F G H J K|<false> 2021-01-01 10:11:12.0000 2020-01-01 10:20:30.5000 2020-02-03 2020-01-01 00:00:00.0000|B D F G H Z|Ab 1 1.50 9 <true> 7|ID NAME N|1 dflt <null>|4 e 2|8 <null> <null>|A B C D|4 4 16 17|ID X|1 7|ID N S|1 10 b|2 <null> a|3 30 c|4 20 a|5 <null> b|GEN_ID GEN_ID GEN_ID GEN_ID GEN_ID|13 8 100 10 4|COUNT|2|ID|4" ]; then echo "FAIL 9 - THE ENGINE ANSWERS [$ev] on its own file"; fail=1
elif [ "$ev" != "$fv" ]; then echo "FAIL 9 the ENGINE reads fc's file differently"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
else echo "OK   9 the ENGINE reads fc's file [$ev]"; fi

# ...and the review of the merged binary's tables: the overflowing row
# kept its 32000 (the engine raises reading it), the rolled-back rename
# never landed, the lookups through the reactivated index answer
FILEQ2="SELECT ID FROM W76 WHERE ID = 2; SELECT A FROM W76 WHERE ID = 1; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'W47' ORDER BY RDB\$FIELD_POSITION; SELECT ID FROM W20 WHERE A = 7 ORDER BY ID; SELECT ID FROM W20 WHERE ID = 3; SELECT ID FROM W21 WHERE ID = 1;"
ran=$((ran + 1))
ev=$(sess "127.0.0.1/$REAL:$ENG" "$FILEQ2"); fv=$(sess "127.0.0.1/$REAL:$FC" "$FILEQ2")
if [ -n "${CAPTURE:-}" ]; then printf 'CAP\t%s\t%s\t%s\n' "11 file" "$ev" "$fv"
elif [ "$ev" != "ID|2|A|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|RDB\$FIELD_NAME|ID|B|AA|ID|3|4|ID|3|ID|1" ]; then echo "FAIL 11 file - THE ENGINE ANSWERS [$ev] on its own file"; fail=1
elif [ "$ev" != "$fv" ]; then echo "FAIL 11 the ENGINE reads fc's file differently"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
else echo "OK   11 the ENGINE reads fc's file [$ev]"; fi

ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-ddlref-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
else echo "OK   no panic"; fi
echo "ran $ran checks"
if [ "$ran" -lt 212 ]; then echo "FAIL only $ran checks ran (floor 212)"; fail=1; fi
exit $fail
