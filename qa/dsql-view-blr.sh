#!/bin/bash
# SQL -> BLR, against the engine's own compiler. For every statement in
# the battery: the ENGINE runs CREATE VIEW <v> AS <select> - its DSQL
# compiles the SELECT and stores the BLR verbatim in RDB$VIEW_BLR -
# and fire-crab-dsql compiles the identical statement. THE BYTES MUST
# MATCH. This is the purest differential in the project: the oracle is
# the exact artifact under conversion, produced by the original
# compiler on demand.
#
# The battery deliberately goes BEYOND the probes the unit tests pin -
# fresh combinations, so the gate tests the COMPILER, not the probe
# notebook. A statement fire-crab-dsql refuses is only OK if it is in
# the REFUSE list; a refusal of a battery statement is a failure.
#
#   qa/dsql-view-blr.sh
#
# Builds its own scratch database.

set -u
FCDSQL="${FCDSQL:-$(dirname "$0")/../target/release/fcdsql}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-dsqlblr.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMPLOYEE (
  EMP_NO INTEGER NOT NULL,
  DEPT_ID INTEGER,
  SALARY INTEGER,
  FIRST_NAME VARCHAR(20),
  RATE NUMERIC(9,2),
  HIRED DATE
);
COMMIT;
EOF

fail=0
n=0
check() { # <select statement>
    n=$((n + 1))
    v="GV$n"
    got=$("$FCDSQL" "$1")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE VIEW $v AS $1;
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$VIEW_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(250) CHARACTER SET OCTETS) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = '$v';
SQL
)
    if [ -z "$want" ]; then
        echo "DIFF [$1] - the engine did not store a view (bad battery statement?)"
        fail=1
    elif [ "$got" = "$want" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $want"
        echo "     fcdsql: $got"
        fail=1
    fi
}
refuse() { # <statement fire-crab-dsql must refuse>
    if [ "$("$FCDSQL" "$1")" = "REFUSED" ]; then
        echo "OK   refused: $1"
    else
        echo "DIFF [$1] compiled instead of refusing"; fail=1
    fi
}

# --- the battery: fresh statements, none of them unit-test pins --------
check "SELECT EMP_NO FROM EMPLOYEE"
check "SELECT EMP_NO, SALARY, FIRST_NAME FROM EMPLOYEE"
check "SELECT EMP_NO FROM EMPLOYEE WHERE SALARY > 40000"
check "SELECT EMP_NO FROM EMPLOYEE WHERE DEPT_ID = 600"
check "SELECT EMP_NO FROM EMPLOYEE WHERE FIRST_NAME = 'Robert'"
check "SELECT EMP_NO FROM EMPLOYEE WHERE SALARY >= 10000 AND SALARY <= 90000"
check "SELECT EMP_NO FROM EMPLOYEE WHERE DEPT_ID = 100 OR DEPT_ID = 600 OR DEPT_ID = 900"
check "SELECT EMP_NO FROM EMPLOYEE WHERE NOT (SALARY <= 40000)"
check "SELECT EMP_NO FROM EMPLOYEE WHERE NOT (DEPT_ID = 100 AND SALARY > 1)"
check "SELECT EMP_NO FROM EMPLOYEE WHERE FIRST_NAME IS NULL"
check "SELECT EMP_NO FROM EMPLOYEE WHERE FIRST_NAME IS NOT NULL"
check "SELECT EMP_NO FROM EMPLOYEE WHERE RATE = 0.05"
check "SELECT EMP_NO FROM EMPLOYEE WHERE RATE <> 99.9"
check "SELECT EMP_NO FROM EMPLOYEE WHERE SALARY BETWEEN 20000 AND 30000"
check "SELECT EMP_NO FROM EMPLOYEE WHERE SALARY NOT BETWEEN 20000 AND 30000"
check "SELECT EMP_NO FROM EMPLOYEE WHERE FIRST_NAME LIKE 'Rob%'"
check "SELECT EMP_NO FROM EMPLOYEE WHERE FIRST_NAME NOT LIKE '%x%'"
check "SELECT EMP_NO FROM EMPLOYEE WHERE DEPT_ID = EMP_NO"
check "SELECT EMP_NO FROM EMPLOYEE WHERE (DEPT_ID = 100 OR DEPT_ID = 600) AND SALARY > 500"
check "SELECT EMP_NO FROM EMPLOYEE WHERE NOT (FIRST_NAME LIKE 'a%' OR RATE IS NULL)"
check "SELECT EMP_NO FROM EMPLOYEE WHERE NOT (NOT (SALARY = 1))"

# --- refusals: outside the converted surface, never guessed ------------
refuse "SELECT EMP_NO FROM EMPLOYEE ORDER BY EMP_NO"
refuse "SELECT EMP_NO FROM EMPLOYEE WHERE SALARY + 1 > 5"
refuse "SELECT EMP_NO FROM EMPLOYEE WHERE DEPT_ID IN (100, 600)"
refuse "SELECT COUNT(*) FROM EMPLOYEE"
refuse "SELECT E.EMP_NO FROM EMPLOYEE E JOIN EMPLOYEE D ON E.EMP_NO = D.EMP_NO"

exit $fail
