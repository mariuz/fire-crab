#!/bin/bash
# DDL UNDER A USER SAVEPOINT IS REFUSED (Firebird 6.0.0.2196 - upstream
# acf041e5 "Disable DDL under user savepoint", 265cca35 its follow-up).
#
# DsqlDdlRequest::execute walks the transaction's savepoint stack before
# the DDL node runs and raises isc_user_savepoint, naming the INNERMOST
# user savepoint, inside the DDL wrapper:
#
#   Statement failed, SQLSTATE = 0A000
#   unsuccessful metadata update
#   -CREATE TABLE "PUBLIC"."T2" failed
#   -Running under user savepoint B, DDL prohibited
#
# Every DDL form is refused - an object that does not exist included,
# the check comes first - and DML and GEN_ID still run. RELEASE and
# ROLLBACK TO move the innermost name; with no user savepoint left (all
# released, or the transaction ended) DDL runs again. The `<VERB> @1
# failed` item is the statement's OWN form: RECREATE and CREATE OR ALTER
# their own verbs, CREATE GENERATOR the SEQUENCE one, SET STATISTICS
# INDEX the ALTER INDEX one; GRANT / REVOKE / ALTER DATABASE carry no
# object; a role prints bare, a column `"PUBLIC"."T".C`.
#
# (A schema-qualified CREATE TABLE PUBLIC.T7 and an empty PSQL body are
# refused at PREPARE by this server whatever the savepoints - separate,
# pre-existing gaps - so the cells avoid them.)
#
# Every cell runs one isql script against the ENGINE and against
# fire-crab on twin files and compares the whole output.
#
#   qa/serve-real-ddlsavepoint.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4588}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
A="$D/fc-ddlsp-crab.fdb"
B="$D/fc-ddlsp-engine.fdb"
LOG="/tmp/fc-serve-ddlsp-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|127.0.0.1/$REAL:$1|" > "$D/ddlsp-$PORT.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER, V VARCHAR(10));
CREATE SEQUENCE SQ;
CREATE INDEX TIX ON T (ID);
CREATE EXCEPTION EX 'boom';
CREATE DOMAIN DM INTEGER;
CREATE ROLE R1;
CREATE VIEW VW AS SELECT ID FROM T;
SET TERM ^ ;
CREATE PROCEDURE P1 AS BEGIN END^
CREATE FUNCTION F1 (X INTEGER) RETURNS INTEGER AS BEGIN RETURN X; END^
CREATE TRIGGER TR FOR T BEFORE INSERT AS BEGIN END^
SET TERM ; ^
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/ddlsp-$PORT.sql" >/dev/null 2>&1
    [ -s "$1" ] || return 1
}
make_db "$B" || { echo "FAIL fixture"; exit 1; }
cp "$B" "$A"; chmod 666 "$A"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/ddlsp-$PORT.sql"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# one isql session, AUTODDL off (so DDL runs in the user transaction,
# where the savepoint is), on each file; the whole output compared
both() {
    ran=$((ran + 1))
    local e c
    e=$(printf 'SET AUTODDL OFF;\nSET LIST ON;\n%s\nROLLBACK;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET AUTODDL OFF;\nSET LIST ON;\n%s\nROLLBACK;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    if [ -z "$e" ]; then echo "FAIL $1 [the engine printed nothing]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 the innermost user savepoint is named; RELEASE / ROLLBACK TO move it"
both "1 nested, released, rolled back to" \
"SAVEPOINT A;
SAVEPOINT B;
CREATE TABLE T2 (X INTEGER);
RELEASE SAVEPOINT B;
CREATE TABLE T3 (X INTEGER);
ROLLBACK TO SAVEPOINT A;
CREATE TABLE T4 (X INTEGER);
RELEASE SAVEPOINT A;
CREATE TABLE T5 (X INTEGER);
SELECT COUNT(*) AS N FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME IN ('T2', 'T3', 'T4', 'T5');"
both "1 a lower-case savepoint name prints as stored" \
"SAVEPOINT low1;
CREATE TABLE T2 (X INTEGER);"
both "1 after ROLLBACK the transaction holds no savepoint" \
"SAVEPOINT S;
ROLLBACK;
CREATE TABLE T2 (X INTEGER);
SELECT COUNT(*) AS N FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T2';"
both "1 after COMMIT neither" \
"SAVEPOINT S;
COMMIT;
CREATE SEQUENCE SQ9;
SELECT COUNT(*) AS N FROM RDB\$GENERATORS WHERE RDB\$GENERATOR_NAME = 'SQ9';
DROP SEQUENCE SQ9;
COMMIT;"

echo "--- 2 every DDL form is refused, the verb its own"
for stmt in \
    "CREATE TABLE T2 (X INTEGER);" \
    "CREATE TABLE \"t q\" (X INTEGER);" \
    "CREATE GLOBAL TEMPORARY TABLE GT (X INTEGER) ON COMMIT DELETE ROWS;" \
    "RECREATE TABLE T5 (X INTEGER);" \
    "ALTER TABLE T ADD W INTEGER;" \
    "ALTER TABLE T ALTER COLUMN V TYPE VARCHAR(20);" \
    "DROP TABLE T;" \
    "DROP TABLE NOPE;" \
    "CREATE INDEX T2IX ON T (V);" \
    "CREATE UNIQUE DESCENDING INDEX UX ON T (ID);" \
    "ALTER INDEX TIX INACTIVE;" \
    "SET STATISTICS INDEX TIX;" \
    "DROP INDEX TIX;" \
    "CREATE SEQUENCE S2;" \
    "CREATE GENERATOR G2;" \
    "ALTER SEQUENCE SQ RESTART WITH 5;" \
    "SET GENERATOR SQ TO 7;" \
    "DROP SEQUENCE SQ;" \
    "CREATE EXCEPTION E2 'x';" \
    "ALTER EXCEPTION EX 'y';" \
    "CREATE OR ALTER EXCEPTION EX 'z';" \
    "RECREATE EXCEPTION EX 'z';" \
    "DROP EXCEPTION EX;" \
    "CREATE DOMAIN D2 INTEGER;" \
    "ALTER DOMAIN DM SET DEFAULT 1;" \
    "DROP DOMAIN DM;" \
    "CREATE ROLE R2;" \
    "DROP ROLE R1;" \
    "GRANT SELECT ON T TO R1;" \
    "REVOKE SELECT ON T FROM R1;" \
    "COMMENT ON TABLE T IS 'c';" \
    "COMMENT ON COLUMN T.ID IS 'c';" \
    "COMMENT ON ROLE R1 IS 'c';" \
    "CREATE VIEW V2 AS SELECT 1 X FROM RDB\$DATABASE;" \
    "ALTER VIEW VW AS SELECT ID FROM T;" \
    "CREATE OR ALTER VIEW VW AS SELECT ID FROM T;" \
    "RECREATE VIEW VW AS SELECT ID FROM T;" \
    "DROP VIEW VW;" \
    "ALTER TRIGGER TR INACTIVE;" \
    "DROP TRIGGER TR;" \
    "DROP PROCEDURE P1;" \
    "DROP FUNCTION F1;"
do
    both "2 $stmt" "SAVEPOINT S;
$stmt"
done
both "2 a PSQL body: CREATE OR ALTER PROCEDURE" \
"SAVEPOINT S;
SET TERM ^ ;
CREATE OR ALTER PROCEDURE P1 AS BEGIN EXIT; END^
RECREATE PROCEDURE P1 AS BEGIN EXIT; END^
ALTER PROCEDURE P1 AS BEGIN EXIT; END^
CREATE FUNCTION F2 RETURNS INTEGER AS BEGIN RETURN 1; END^
CREATE OR ALTER TRIGGER TR FOR T BEFORE INSERT AS BEGIN NEW.ID = 1; END^
SET TERM ; ^"

echo "--- 3 CONTROLS: DML and a generator still run under a savepoint"
both "3 INSERT, UPDATE, GEN_ID and a read" \
"SAVEPOINT S;
INSERT INTO T VALUES (1, 'a');
UPDATE T SET V = 'b' WHERE ID = 1;
SELECT GEN_ID(SQ, 1) AS G FROM RDB\$DATABASE;
SELECT ID, V FROM T;"
both "3 the refused DDL wrote nothing: the table is still there" \
"SAVEPOINT S;
DROP TABLE T;
RELEASE SAVEPOINT S;
SELECT COUNT(*) AS N FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T';"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "$LOG"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
exit $fail
