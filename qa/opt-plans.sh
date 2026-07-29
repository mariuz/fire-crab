#!/bin/bash
# ACCESS-PATH SELECTION, oracle number five: the engine's own PLAN.
# `SET PLANONLY ON` makes the engine PREPARE a statement and print the
# plan it chose - which index fetches the rows, whether an ORDER BY
# rides an index's order or needs a sort - without executing anything.
# That is a complete, textual statement of the optimizer's decision,
# and `fcopt plan` must print the SAME LINE for the SAME statement.
#
# The battery walks the decision surface: no predicate, matchable and
# unmatchable comparisons, AND/OR structure, indexed and unindexed
# columns, navigation with and without a direction match, and the
# SORT wrapper. Refusals (joins, unions, subqueries, multi-column
# ORDER) must answer REFUSED - a plan this crate cannot justify is
# never printed.
#
#   qa/opt-plans.sh
#
# Builds its own scratch database.

set -u
FCOPT="${FCOPT:-$(dirname "$0")/../target/release/fcopt}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-optplans.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(20), NOTE VARCHAR(20));
CREATE TABLE U (UID INTEGER, UA INTEGER);
CREATE INDEX IDX_T_ID ON T (ID);
CREATE INDEX IDX_T_AMT ON T (AMT);
CREATE INDEX IDX_T_NAME ON T (NAME);
CREATE DESCENDING INDEX IDX_T_AMT_D ON T (AMT);
CREATE INDEX IDX_U_UID ON U (UID);
COMMIT;
EOF

fail=0
check() { # <sql> - the engine's plan must equal fcopt's
    want=$("$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$1;
SQL
)
    got=$("$FCOPT" plan "$DB" "$1" 2>&1)
    if [ "$got" = "$want" ]; then
        echo "OK   $1"
        echo "     $got"
    else
        echo "DIFF $1"
        echo "     engine: $want"
        echo "     fcopt:  $got"
        fail=1
    fi
}
refuse() { # <sql> - outside the slice: fcopt must refuse
    got=$("$FCOPT" plan "$DB" "$1" 2>&1)
    case "$got" in
        REFUSED*) echo "OK   refused: $1" ;;
        *) echo "DIFF [$1] expected REFUSED, got: $got"; fail=1 ;;
    esac
}

# --- no predicate, and unusable ones -> NATURAL ------------------------
check "SELECT ID FROM T"
check "SELECT COUNT(*) FROM T"
check "SELECT ID FROM T WHERE NOTE = 'x'"
check "SELECT ID FROM T WHERE ID <> 5"
check "SELECT ID FROM T WHERE ID IS NOT NULL"
check "SELECT ID FROM T WHERE NAME LIKE '%a'"

# --- matchable comparisons -> INDEX -----------------------------------
check "SELECT ID FROM T WHERE ID = 5"
check "SELECT ID FROM T WHERE AMT > 3"
check "SELECT ID FROM T WHERE AMT <= 3"
check "SELECT ID FROM T WHERE ID BETWEEN 1 AND 9"
check "SELECT ID FROM T WHERE ID IS NULL"
check "SELECT ID FROM T WHERE NAME STARTING WITH 'a'"
check "SELECT ID FROM T WHERE NAME LIKE 'a%'"

# --- AND / OR structure ------------------------------------------------
check "SELECT ID FROM T WHERE ID = 5 AND AMT = 3"
check "SELECT ID FROM T WHERE ID = 5 AND AMT = 3 AND NAME = 'x'"
check "SELECT ID FROM T WHERE ID = 5 AND NOTE = 'x'"
check "SELECT ID FROM T WHERE ID = 5 OR AMT = 3"
check "SELECT ID FROM T WHERE ID = 5 OR NOTE = 'x'"

# --- navigation, direction matching, and the SORT wrapper -------------
check "SELECT ID FROM T ORDER BY ID"
check "SELECT ID FROM T ORDER BY AMT"
check "SELECT ID FROM T ORDER BY AMT DESC"
check "SELECT ID FROM T ORDER BY ID DESC"
check "SELECT ID FROM T ORDER BY NOTE"
check "SELECT ID FROM T WHERE ID > 3 ORDER BY ID"
check "SELECT ID FROM T WHERE AMT > 3 ORDER BY ID"
check "SELECT ID FROM T WHERE NOTE = 'x' ORDER BY ID"

# --- outside the slice -------------------------------------------------
refuse "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID"
refuse "SELECT ID FROM T UNION ALL SELECT UID FROM U"
refuse "SELECT ID FROM T WHERE ID IN (SELECT UID FROM U)"
refuse "SELECT ID FROM T ORDER BY ID, AMT"
refuse "SELECT ID FROM T, U"

exit $fail
