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

# --- slice 17: domain defaults, expression indexes, CHECKs -------------
check_dom() { # <type> <default clause> - domain defaults live on RDB$FIELDS
    n=$((n + 1))
    dom="GDOM$n"
    got=$("$FCDSQL" "$2")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE DOMAIN $dom AS $1 $2;
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$DEFAULT_VALUE AS BLOB SUB_TYPE 0) AS VARCHAR(200) CHARACTER SET OCTETS) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = '$dom';
SQL
)
    if [ -z "$want" ]; then echo "DIFF [$1 $2] - no domain default stored"; fail=1
    elif [ "$got" = "$want" ]; then echo "OK   DOMAIN $1 $2"
    else echo "DIFF DOMAIN $1 $2"; echo "     engine: $want"; echo "     fcdsql: $got"; fail=1; fi
}
check_ix() { # <computed by clause> - expression indexes on GI(A,B,S)
    n=$((n + 1))
    ix="GIX$n"
    got=$("$FCDSQL" "$1")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE INDEX $ix ON GIBASE $1;
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$EXPRESSION_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(200) CHARACTER SET OCTETS) FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = '$ix';
SQL
)
    if [ -z "$want" ]; then echo "DIFF [$1] - no index expression stored"; fail=1
    elif [ "$got" = "$want" ]; then echo "OK   INDEX $1"
    else echo "DIFF INDEX $1"; echo "     engine: $want"; echo "     fcdsql: $got"; fail=1; fi
}
check_ck() { # <check clause> - the constraint's system trigger on GK(A,B,S)
    n=$((n + 1))
    tbl="GK$n"
    got=$("$FCDSQL" "$1")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE TABLE $tbl (A INTEGER, B INTEGER, S VARCHAR(10), CONSTRAINT ${tbl}_C $1);
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT FIRST 1 CAST(CAST(RDB\$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS) FROM RDB\$TRIGGERS WHERE RDB\$RELATION_NAME = '$tbl';
SQL
)
    if [ -z "$want" ]; then echo "DIFF [$1] - no check trigger stored"; fail=1
    elif [ "$got" = "$want" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $want"; echo "     fcdsql: $got"; fail=1; fi
}
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE TABLE GIBASE (A INTEGER, B INTEGER, S VARCHAR(10));
COMMIT;
SQL

check_dom "INTEGER" "DEFAULT 7"
check_dom "VARCHAR(5)" "DEFAULT 'x'"
check_dom "TIMESTAMP" "DEFAULT CURRENT_TIMESTAMP"
check_ix "COMPUTED BY (UPPER(S))"
check_ix "COMPUTED BY (A + B)"
check_ix "COMPUTED BY (A * 2 - B)"
check_ck "CHECK (A < B)"
check_ck "CHECK (A > 0)"
check_ck "CHECK (A IS NOT NULL)"
check_ck "CHECK (A BETWEEN 1 AND 100)"
check_ck "CHECK (A > 0 AND B > 0)"

# --- slice 18: domain validation ---------------------------------------
check_val() { # <type> <check clause> - RDB$VALIDATION_BLR
    n=$((n + 1))
    dom="GVD$n"
    got=$("$FCDSQL" "$2")
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
CREATE DOMAIN $dom AS $1 $2;
COMMIT;
SQL
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$VALIDATION_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = '$dom';
SQL
)
    if [ -z "$want" ]; then echo "DIFF [$1 $2] - no validation stored"; fail=1
    elif [ "$got" = "$want" ]; then echo "OK   DOMAIN $1 $2"
    else echo "DIFF DOMAIN $1 $2"; echo "     engine: $want"; echo "     fcdsql: $got"; fail=1; fi
}
check_val "INTEGER" "CHECK (VALUE > 0)"
check_val "INTEGER" "CHECK (VALUE BETWEEN 1 AND 12)"
check_val "VARCHAR(10)" "CHECK (VALUE IS NOT NULL)"
check_val "VARCHAR(10)" "CHECK (CHAR_LENGTH(VALUE) > 2 AND UPPER(VALUE) LIKE 'A%')"
check_val "INTEGER" "CHECK (VALUE IN (1, 2, 3))"

# --- refusals ----------------------------------------------------------
refuse "DEFAULT 3 + 4"
refuse "DEFAULT SOMECOLUMN"
refuse "COMPUTED BY (T.C1)"
# a FIELD branch under a CASE's cast wrapper needs the CATALOG's
# column descriptor - the engine compiles it, a catalog-free compiler
# refuses rather than guess
refuse "COMPUTED BY (CASE WHEN A > B THEN A ELSE B END)"
# non-integer IN items are cast to the column's CATALOG type by the
# engine (probed) - catalog-free refuses
refuse "CHECK (S IN ('a', 'b'))"

exit $fail
