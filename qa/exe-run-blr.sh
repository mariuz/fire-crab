#!/bin/bash
# BLR -> ROWS, the execution differential. fire-crab-exe picks up the
# compiled BLR the ENGINE stored in RDB$PROCEDURE_BLR - the same blob
# fire-crab-dsql matches byte-for-byte from the SQL text - and EXECUTES
# it against the database file through fire-crab-ods' committed-
# visibility scan. The engine then runs the same procedure through
# SELECT * FROM <proc>, and the rows must be identical:
#
#   SQL --(fcdsql, byte-checked)--> BLR --(fcexe)--> rows == engine rows
#
# Phase A re-asserts the first arrow on this battery (fcdsql compiles
# each CREATE PROCEDURE to the exact stored bytes), so phase B is
# guaranteed to execute bytes fire-crab can also PRODUCE. Refusals:
# shapes outside the slice (input parameters, joins, aggregates) must
# answer REFUSED - an unknown verb is an error, never a guess.
#
#   qa/exe-run-blr.sh
#
# Builds its own scratch database. Values carry no internal spaces, so
# the engine's column output can be pipe-collapsed for comparison.

set -u
FCEXE="${FCEXE:-$(dirname "$0")/../target/release/fcexe}"
FCDSQL="${FCDSQL:-$(dirname "$0")/../target/release/fcdsql}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-exerun.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(10));
CREATE TABLE U (UID INTEGER, UA INTEGER);
COMMIT;
INSERT INTO T (ID, AMT, NAME) VALUES (1, 3, 'aa');
INSERT INTO T (ID, AMT, NAME) VALUES (2, 8, 'bb');
INSERT INTO T (ID, AMT, NAME) VALUES (3, NULL, 'cc');
INSERT INTO T (ID, AMT, NAME) VALUES (4, 12, NULL);
INSERT INTO T (ID, AMT, NAME) VALUES (5, 8, 'ee');
INSERT INTO U (UID, UA) VALUES (1, 100);
INSERT INTO U (UID, UA) VALUES (2, 200);
INSERT INTO U (UID, UA) VALUES (7, 700);
COMMIT;
EOF

fail=0
n=0
check() { # <procedure tail after "CREATE PROCEDURE <name> ">
    n=$((n + 1))
    name="EP$n"
    stmt="CREATE PROCEDURE $name ${1}"
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
SET TERM ^ ;
$stmt^
SET TERM ; ^
COMMIT;
SQL
    # --- phase A: fcdsql must still match the stored bytes ---
    stored=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$PROCEDURE_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(900) CHARACTER SET OCTETS) FROM RDB\$PROCEDURES WHERE RDB\$PROCEDURE_NAME = '$name';
SQL
)
    compiled=$("$FCDSQL" "$stmt")
    if [ -z "$stored" ]; then
        echo "DIFF [$stmt] - the engine did not store the procedure"
        fail=1
        return
    fi
    if [ "$compiled" != "$stored" ]; then
        echo "DIFF $stmt"
        echo "     fcdsql no longer matches the stored BLR"
        fail=1
        return
    fi
    # --- phase B: fcexe executes the stored bytes; rows == engine ---
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/|/g' | grep -v '^$'
SET HEADING OFF;
SELECT * FROM $name;
SQL
)
    got=$("$FCEXE" "$DB" "$name" 2>&1)
    if [ "$got" = "$want" ]; then
        echo "OK   $stmt"
    else
        echo "DIFF $stmt"
        echo "     engine: $(printf '%s' "$want" | tr '\n' ' ')"
        echo "     fcexe:  $(printf '%s' "$got" | tr '\n' ' ')"
        fail=1
    fi
}
checkp() { # <args> <procedure tail> - a parameterized check: the
           # engine answers SELECT * FROM name(<args>), fcexe takes
           # the same values as CLI arguments; phase A still pins the
           # stored bytes against fcdsql
    cargs="$1"; shift
    n=$((n + 1))
    name="EP$n"
    stmt="CREATE PROCEDURE $name ${1}"
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
SET TERM ^ ;
$stmt^
SET TERM ; ^
COMMIT;
SQL
    stored=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<SQL | tr -d ' 
'
SET HEADING OFF;
SELECT CAST(CAST(RDB\$PROCEDURE_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(900) CHARACTER SET OCTETS) FROM RDB\$PROCEDURES WHERE RDB\$PROCEDURE_NAME = '$name';
SQL
)
    if [ -z "$stored" ] || [ "$("$FCDSQL" "$stmt")" != "$stored" ]; then
        echo "DIFF [$stmt] - store/byte-pin failure"; fail=1; return
    fi
    # SQL-side spelling: numeric args ride bare, text args quote
    sqlargs=""
    for a in $cargs; do
        case "$a" in
            ''|*[!0-9-]*) q="'$a'" ;;
            *) q="$a" ;;
        esac
        sqlargs="$sqlargs${sqlargs:+,}$q"
    done
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/|/g' | grep -v '^$'
SET HEADING OFF;
SELECT * FROM $name($sqlargs);
SQL
)
    got=$("$FCEXE" "$DB" "$name" $cargs 2>&1)
    if [ "$got" = "$want" ]; then
        echo "OK   ($cargs) $stmt"
    else
        echo "DIFF ($cargs) $stmt"
        echo "     engine: $(printf '%s' "$want" | tr '
' ' ')"
        echo "     fcexe:  $(printf '%s' "$got" | tr '
' ' ')"
        fail=1
    fi
}
refuse() { # <procedure tail> - the engine runs it; fcexe must refuse
    n=$((n + 1))
    name="EP$n"
    stmt="CREATE PROCEDURE $name ${1}"
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<SQL
SET TERM ^ ;
$stmt^
SET TERM ; ^
COMMIT;
SQL
    got=$("$FCEXE" "$DB" "$name" 2>&1)
    rc=$?
    case "$got" in
        REFUSED*) [ $rc -ne 0 ] && { echo "OK   refused: $stmt"; return; } ;;
    esac
    echo "DIFF [$stmt] - expected REFUSED, got: $(printf '%s' "$got" | tr '\n' ' ')"
    fail=1
}

# --- the battery: every converted shape, straight and edged ------------
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT > 5 INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER, R3 VARCHAR(10)) AS BEGIN FOR SELECT ID, AMT, NAME FROM T INTO :R1, :R2, :R3 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT IS NULL INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT IS NOT NULL INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT > 5 AND ID < 4 INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID = 1 OR AMT = 12 INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE NOT (AMT > 5) INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT > 100 INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 VARCHAR(10)) AS BEGIN FOR SELECT NAME FROM T WHERE NAME <> 'aa' INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, AMT FROM T ORDER BY AMT INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, AMT FROM T ORDER BY AMT DESC INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, AMT FROM T ORDER BY AMT DESC, ID DESC INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 VARCHAR(10)) AS BEGIN FOR SELECT NAME FROM T ORDER BY NAME INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT >= 8 AND (ID = 2 OR NAME = 'ee') INTO :R1 DO SUSPEND; END"

# --- slice 2: parameters, aggregates, singular, FIRST/SKIP -------------
# (input parameters, COUNT(*) and the singular SELECT INTO - all
# slice-1 refusals - flipped)
checkp "5" "(P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT > :P1 INTO :R1 DO SUSPEND; END"
checkp "8 3" "(P1 INTEGER, P2 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT = :P1 AND ID > :P2 INTO :R1 DO SUSPEND; END"
checkp "bb" "(P1 VARCHAR(10)) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE NAME = :P1 INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM T INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(AMT) FROM T INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER, R3 INTEGER) AS BEGIN FOR SELECT SUM(AMT), MIN(AMT), MAX(AMT) FROM T INTO :R1, :R2, :R3 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT AVG(AMT) FROM T INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM T WHERE AMT > 100 INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT AMT, COUNT(*) FROM T GROUP BY AMT INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT AMT, SUM(ID) FROM T GROUP BY AMT HAVING COUNT(*) > 1 INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN SELECT ID FROM T WHERE ID = 1 INTO :R1; SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST 2 SKIP 1 ID FROM T ORDER BY ID DESC INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST 3 ID FROM T ORDER BY AMT INTO :R1 DO SUSPEND; END"

# --- slice 3: expressions, joins, DISTINCT -----------------------------
# (ID + 1, the join and DISTINCT - slice-1/2 refusals - flipped)
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID + 1 FROM T INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID * 10 + AMT FROM T WHERE AMT / 2 > 3 INTO :R1 DO SUSPEND; END"
checkp "3" "(P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT AMT - :P1 FROM T WHERE AMT IS NOT NULL ORDER BY ID INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 VARCHAR(30)) AS BEGIN FOR SELECT NAME || '-x' FROM T WHERE NAME IS NOT NULL INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT -AMT FROM T WHERE AMT > 5 ORDER BY ID INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A.ID, B.UA FROM T A JOIN U B ON A.ID = B.UID INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A.ID, B.UA FROM T A JOIN U B ON A.ID = B.UID WHERE B.UA > 100 INTO :R1, :R2 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM T A JOIN U B ON A.ID = B.UID INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT DISTINCT AMT FROM T INTO :R1 DO SUSPEND; END"
check "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT DISTINCT AMT FROM T ORDER BY AMT DESC INTO :R1 DO SUSPEND; END"

# --- refusals: outside the slice, the answer is REFUSED ----------------
refuse "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UID INTO :R1 DO SUSPEND; END"
refuse "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) OVER () FROM T INTO :R1 DO SUSPEND; END"
refuse "RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM (SELECT ID FROM T) A INTO :R1 DO SUSPEND; END"

exit $fail
