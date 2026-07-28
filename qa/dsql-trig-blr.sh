#!/bin/bash
# SQL -> BLR, oracle number THREE: RDB$TRIGGER_BLR. A trigger body is
# compiled by the same DSQL and stored verbatim - and its wrapper is
# the leanest of the three oracles. For every statement in the battery:
# the ENGINE runs the CREATE TRIGGER and fire-crab-dsql compiles the
# identical text. THE BYTES MUST MATCH.
#
# OLD is context 0, NEW is context 1; the header (table, BEFORE/AFTER,
# event, POSITION) leaves NO trace in the BLR - catalog data, like a
# view's select list.
#
#   qa/dsql-trig-blr.sh
#
# Builds its own scratch database.

set -u
FCDSQL="${FCDSQL:-$(dirname "$0")/../target/release/fcdsql}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-dsqltrig.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMPLOYEE (
  EMP_NO INTEGER NOT NULL,
  DEPT_ID INTEGER,
  SALARY INTEGER,
  FIRST_NAME VARCHAR(20),
  RATE NUMERIC(9,2)
);
COMMIT;
EOF

fail=0
n=0
check() { # <trigger tail after CREATE TRIGGER name>
    n=$((n + 1))
    name="GT$n"
    stmt="CREATE TRIGGER $name ${1}"
    got=$("$FCDSQL" "$stmt")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
SET TERM ^ ;
$stmt^
SET TERM ; ^
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(600) CHARACTER SET OCTETS) FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME = '$name';
SQL
)
    if [ -z "$want" ]; then
        echo "DIFF [$stmt] - the engine did not store a trigger (bad battery statement?)"
        fail=1
    elif [ "$got" = "$want" ]; then
        echo "OK   $stmt"
    else
        echo "DIFF $stmt"
        echo "     engine: $want"
        echo "     fcdsql: $got"
        fail=1
    fi
}
refuse() {
    if [ "$("$FCDSQL" "$1")" = "REFUSED" ]; then
        echo "OK   refused: $1"
    else
        echo "DIFF [$1] compiled instead of refusing"; fail=1
    fi
}

# --- the battery -------------------------------------------------------
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN NEW.SALARY = 0; END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN IF (NEW.SALARY IS NULL) THEN NEW.SALARY = 100; END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN NEW.SALARY = OLD.SALARY + 50; END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN IF (NEW.SALARY < OLD.SALARY) THEN NEW.DEPT_ID = 0; ELSE NEW.DEPT_ID = OLD.DEPT_ID; END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN NEW.FIRST_NAME = UPPER(NEW.FIRST_NAME); NEW.DEPT_ID = 100; END"
check "FOR EMPLOYEE BEFORE INSERT POSITION 3 AS BEGIN NEW.RATE = 1.25; END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN IF (OLD.DEPT_ID <> NEW.DEPT_ID AND NEW.SALARY > 0) THEN BEGIN NEW.SALARY = NEW.SALARY / 2; NEW.RATE = 0.5; END END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN IF (CHAR_LENGTH(NEW.FIRST_NAME) > 10) THEN NEW.FIRST_NAME = SUBSTRING(NEW.FIRST_NAME FROM 1 FOR 10); END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN NEW.SALARY = CASE WHEN OLD.SALARY > 1000 THEN 1000 ELSE 0 END; END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN IF (NEW.DEPT_ID IN (100, 600)) THEN NEW.RATE = 2.5; END"

# --- slice 12: DML statements ------------------------------------------
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN INSERT INTO EMPLOYEE (EMP_NO, SALARY) VALUES (0, 100); END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN INSERT INTO EMPLOYEE (EMP_NO, FIRST_NAME) VALUES (NEW.EMP_NO + 1000, UPPER(NEW.FIRST_NAME)); END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN DELETE FROM EMPLOYEE WHERE EMPLOYEE.SALARY < 0; END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN DELETE FROM EMPLOYEE WHERE DEPT_ID = OLD.DEPT_ID AND SALARY = 0; END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN UPDATE EMPLOYEE SET SALARY = SALARY + 10 WHERE EMPLOYEE.DEPT_ID = NEW.DEPT_ID; END"
check "FOR EMPLOYEE BEFORE UPDATE AS BEGIN UPDATE EMPLOYEE SET RATE = 1.5, DEPT_ID = OLD.DEPT_ID WHERE EMPLOYEE.EMP_NO = 7; END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN IF (NEW.DEPT_ID = 0) THEN DELETE FROM EMPLOYEE WHERE EMPLOYEE.DEPT_ID = 0; END"
check "FOR EMPLOYEE BEFORE INSERT AS BEGIN INSERT INTO EMPLOYEE (EMP_NO) VALUES (1); UPDATE EMPLOYEE SET SALARY = 0 WHERE EMPLOYEE.EMP_NO = 1; END"

# --- refusals ----------------------------------------------------------
refuse "CREATE TRIGGER X FOR EMPLOYEE BEFORE INSERT AS BEGIN OLD.SALARY = 5; END"
refuse "CREATE TRIGGER X FOR EMPLOYEE BEFORE INSERT AS BEGIN SALARY = 5; END"
refuse "CREATE TRIGGER X FOR EMPLOYEE BEFORE INSERT AS BEGIN END"
refuse "CREATE TRIGGER X FOR EMPLOYEE ON CONNECT AS BEGIN NEW.SALARY = 1; END"
refuse "CREATE TRIGGER X FOR EMPLOYEE BEFORE INSERT AS BEGIN INSERT INTO EMPLOYEE VALUES (1); END"
refuse "CREATE TRIGGER X FOR EMPLOYEE BEFORE INSERT AS BEGIN INSERT INTO EMPLOYEE (EMP_NO) SELECT EMP_NO FROM EMPLOYEE; END"

exit $fail
