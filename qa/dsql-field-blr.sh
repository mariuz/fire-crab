#!/bin/bash
# SQL -> BLR, oracle number FOUR: column BLR. A DEFAULT clause is
# compiled by the same DSQL and stored verbatim in
# RDB$RELATION_FIELDS.RDB$DEFAULT_VALUE; a COMPUTED BY expression in
# RDB$FIELDS.RDB$COMPUTED_BLR. Both carry the SMALLEST wrapper of the
# four oracles: blr_version5, the value, blr_eoc.
#
# For every clause in the battery: the ENGINE runs a CREATE TABLE
# carrying it and fire-crab-dsql compiles the identical clause text.
# THE BYTES MUST MATCH.
#
#   qa/dsql-field-blr.sh
#
# Builds its own scratch database.

set -u
FCDSQL="${FCDSQL:-$(dirname "$0")/../target/release/fcdsql}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-dsqlfield.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

fail=0
n=0
check_d() { # <type> <default clause>
    n=$((n + 1))
    tbl="GD$n"
    got=$("$FCDSQL" "$2")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE TABLE $tbl (C0 $1 $2);
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$DEFAULT_VALUE AS BLOB SUB_TYPE 0) AS VARCHAR(200) CHARACTER SET OCTETS) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = '$tbl' AND RDB\$FIELD_NAME = 'C0';
SQL
)
    if [ -z "$want" ]; then
        echo "DIFF [$1 $2] - the engine stored no default (bad battery clause?)"
        fail=1
    elif [ "$got" = "$want" ]; then
        echo "OK   $1 $2"
    else
        echo "DIFF $1 $2"
        echo "     engine: $want"
        echo "     fcdsql: $got"
        fail=1
    fi
}
check_c() { # <computed clause> (table has A, B INTEGER, S VARCHAR(10))
    n=$((n + 1))
    tbl="GC$n"
    got=$("$FCDSQL" "$1")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE TABLE $tbl (A INTEGER, B INTEGER, S VARCHAR(10), CX $1);
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(F.RDB\$COMPUTED_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(200) CHARACTER SET OCTETS) FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON RF.RDB\$FIELD_SOURCE = F.RDB\$FIELD_NAME WHERE RF.RDB\$RELATION_NAME = '$tbl' AND RF.RDB\$FIELD_NAME = 'CX';
SQL
)
    if [ -z "$want" ]; then
        echo "DIFF [$1] - the engine stored no computed blr (bad battery clause?)"
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
refuse() {
    if [ "$("$FCDSQL" "$1")" = "REFUSED" ]; then
        echo "OK   refused: $1"
    else
        echo "DIFF [$1] compiled instead of refusing"; fail=1
    fi
}

# --- defaults ----------------------------------------------------------
check_d "INTEGER" "DEFAULT 100"
check_d "INTEGER" "DEFAULT -1"
check_d "VARCHAR(20)" "DEFAULT 'unknown'"
check_d "INTEGER" "DEFAULT NULL"
check_d "DATE" "DEFAULT CURRENT_DATE"
check_d "TIME" "DEFAULT CURRENT_TIME"
check_d "TIMESTAMP" "DEFAULT CURRENT_TIMESTAMP"
check_d "NUMERIC(9,2)" "DEFAULT 1.25"
check_d "BIGINT" "DEFAULT 5000000000"

# --- computed columns --------------------------------------------------
check_c "COMPUTED BY (A + B)"
check_c "COMPUTED BY (A * B - 1)"
check_c "COMPUTED BY (UPPER(S))"
check_c "COMPUTED BY (S || '!')"
check_c "COMPUTED BY (CASE WHEN A > B THEN 1 ELSE 0 END)"
check_c "COMPUTED BY (COALESCE(A, 0))"
check_c "COMPUTED BY (CAST(A AS BIGINT))"
check_c "COMPUTED BY (SUBSTRING(S FROM 1 FOR 3))"
check_c "COMPUTED BY (CHAR_LENGTH(S) + A)"

# --- refusals ----------------------------------------------------------
refuse "DEFAULT 3 + 4"
refuse "DEFAULT SOMECOLUMN"
refuse "COMPUTED BY (T.C1)"
# a FIELD branch under a CASE's cast wrapper needs the CATALOG's
# column descriptor - the engine compiles it, a catalog-free compiler
# refuses rather than guess
refuse "COMPUTED BY (CASE WHEN A > B THEN A ELSE B END)"

exit $fail
