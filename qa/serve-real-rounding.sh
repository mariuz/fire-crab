#!/bin/bash
# The EXACT-rounding built-ins CEIL / CEILING / FLOOR / ROUND / TRUNC -
# exact-numeric in, exact-numeric out (no f64 for an exact operand), the
# result form derived from the operand the way the engine's makeCeilFloor /
# makeRound / makeTrunc do:
#
#  - CEIL / CEILING / FLOOR promote the operand's storage one dtype step:
#    SMALLINT -> INTEGER, INTEGER / BIGINT -> BIGINT, INT128 stays INT128;
#    scale 0, sub_type 0 (makeLong / makeInt64 / makeInt128).
#  - ROUND / TRUNC copy the operand's descriptor (dtype, sub_type kept); a
#    ONE-argument call forces scale 0 (round / truncate to a whole number),
#    a TWO-argument call keeps the operand scale and rounds to n places.
#  - a literal NULL operand answers INTEGER whatever the function (makeLong).
#  - an APPROXIMATE operand answers DOUBLE; CEIL / FLOOR / TRUNC also
#    string-convert a TEXT operand to DOUBLE (CEIL('3.2') = 4.0).
#
# ROUND rounds half AWAY from zero (ROUND(2.5)=3, ROUND(-2.5)=-3, and at n
# places ROUND(2.25,1)=2.30); TRUNC toward zero. The exact work is in i128,
# so a wide NUMERIC(30) operand keeps its INT128 result.
#
# Covered (fc vs the live engine): the values over literals (one- and
# two-argument, negative, half-way, tens/hundreds); the SQLDA describe for
# every operand form - SMALLINT / INTEGER / BIGINT / NUMERIC(<=18) /
# NUMERIC(30) / a literal - byte for byte (sqltype, scale, sub_type, len);
# the family over SMALLINT / INTEGER / BIGINT / NUMERIC / DOUBLE columns
# with a NULL row; a DOUBLE operand; a text operand (the three that
# convert); and a literal NULL.
#
# Boundaries (recorded, NOT byte-compared here - fc REFUSES where the engine
# answers or names the error, a clean decline):
#  - a DECFLOAT or INT128 operand: the engine computes it in the decimal128
#    domain (CEIL(CAST(3.2 AS DECFLOAT))=4 as a DECFLOAT); fc has no
#    decimal128 rounding and refuses at prepare.
#  - ROUND of a TEXT operand: the engine names "First argument for ROUND
#    must be integral type or floating point type"; fc refuses generically.
#  - a wrong-argument-count call: the engine says "function @ could not be
#    matched" (39000); fc refuses generically (shared by every fc SysFn).
#  - a FLOAT (single-precision) operand: the engine keeps the result FLOAT
#    (makeRound / makeCeilFloor copy the operand descriptor); fc has only one
#    approximate expression type and widens it to DOUBLE, its general policy
#    for an approximate EXPRESSION. A DOUBLE operand is exact; only a FLOAT
#    operand (rare) widens, so this gate uses DOUBLE operands throughout.
#
#   qa/serve-real-rounding.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4947}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-round-crab.fdb"; B="$D/fc-round-engine.fdb"
LOG="/tmp/fc-serve-round-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

SET='CREATE TABLE T(ID INTEGER, S SMALLINT, I INTEGER, BG BIGINT, N NUMERIC(10,4), D DOUBLE PRECISION);
INSERT INTO T VALUES (1, 6, 12, 5000000000, 2.5000, 2.5);
INSERT INTO T VALUES (2, -3, -7, -3, -3.7500, -3.75);
INSERT INTO T VALUES (3, 0, NULL, 8, NULL, NULL);
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

cat > "$D/v.sql" <<'SQL'
SET LIST ON;
SELECT CEIL(3.2) A, CEILING(-3.2) B, FLOOR(3.8) C, FLOOR(-3.2) D, TRUNC(3.78) E, TRUNC(-3.78) F FROM RDB$DATABASE;
SELECT ROUND(3.5) A, ROUND(2.5) B, ROUND(-2.5) C, ROUND(0.5) D, ROUND(1.5) E FROM RDB$DATABASE;
SELECT ROUND(3.14159,2) A, ROUND(3.14559,2) B, TRUNC(3.789,2) C, ROUND(-3.145,2) D, ROUND(1234.5,-2) E, TRUNC(1234.9,-2) F FROM RDB$DATABASE;
SELECT ROUND(2.15,1) A, ROUND(2.25,1) B, ROUND(-2.15,1) C, ROUND(2.5,0) D FROM RDB$DATABASE;
SELECT CEIL(5) A, FLOOR(5) B, ROUND(7) C, TRUNC(7) D, ROUND(1234,-2) E FROM RDB$DATABASE;
SELECT CEIL(NULL) A, ROUND(NULL) B, TRUNC(NULL) C, ROUND(NULL,2) D FROM RDB$DATABASE;
SQL
vof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/v.sql" 2>&1 | norm; }
check "values: 1-arg / 2-arg / negative / half-away / tens / NULL" \
    "$(vof "127.0.0.1/$PORT:$A")" "$(vof "127.0.0.1/$REAL:$B")"

cat > "$D/d.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT CEIL(3.2), FLOOR(3.2), TRUNC(3.2), ROUND(3.2) FROM RDB$DATABASE;
SELECT ROUND(3.14159,2), TRUNC(3.789,2), ROUND(1234.5,-2) FROM RDB$DATABASE;
SELECT CEIL(5), ROUND(7), ROUND(CAST(1234 AS INTEGER),-2) FROM RDB$DATABASE;
SELECT ROUND(CAST(3.2 AS NUMERIC(18,4))), ROUND(CAST(3.2 AS NUMERIC(30,4))), CEIL(CAST(3.2 AS NUMERIC(30,4))) FROM RDB$DATABASE;
SELECT CEIL(CAST(5 AS SMALLINT)), ROUND(CAST(5 AS SMALLINT)), CEIL(CAST(5 AS BIGINT)) FROM RDB$DATABASE;
SELECT CEIL(NULL), ROUND(NULL,2) FROM RDB$DATABASE;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/d.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe (dtype promotion, scale, sub_type, INT128, NULL) matches" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

cat > "$D/c.sql" <<'SQL'
SET LIST ON;
SELECT ID, CEIL(N) A, FLOOR(N) B, ROUND(N) C, TRUNC(N) D, ROUND(N,1) E FROM T ORDER BY ID;
SELECT ID, CEIL(S) A, CEIL(I) B, CEIL(BG) C, ROUND(S) D FROM T ORDER BY ID;
SELECT ID, CEIL(D) A, ROUND(D,1) B, TRUNC(D) C FROM T ORDER BY ID;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/c.sql" 2>&1 | norm; }
check "over SMALLINT/INTEGER/BIGINT/NUMERIC/DOUBLE columns (with a NULL row)" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

cat > "$D/cd.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT CEIL(S), CEIL(I), CEIL(BG), CEIL(N), ROUND(S), ROUND(N,1), FLOOR(D) FROM T;
SQL
cdof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cd.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe over columns (promotion + DOUBLE) matches" \
    "$(cdof "127.0.0.1/$PORT:$A")" "$(cdof "127.0.0.1/$REAL:$B")"

# A DOUBLE / text operand answers DOUBLE; the three that string-convert.
eof() { echo "SELECT $2 N FROM RDB\$DATABASE;" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
for e in "CEIL(CAST(3.2 AS DOUBLE PRECISION))" "ROUND(CAST(3.14159 AS DOUBLE PRECISION),2)" \
         "TRUNC(CAST(3.99 AS DOUBLE PRECISION))" "ROUND(CAST(2.5 AS DOUBLE PRECISION))" \
         "CEIL('3.2')" "CEILING('3.2')" "FLOOR('3.8')" "TRUNC('3.78')" "TRUNC('3.78',1)"; do
    check "double / text operand: $e" \
        "$(eof "127.0.0.1/$PORT:$A" "$e")" "$(eof "127.0.0.1/$REAL:$B" "$e")"
done

# ROUND of an APPROXIMATE operand follows the engine's CVT (d*10^-s, add
# 0.5+eps, truncate), NOT a naive f64 round - so the .x05 binary-representation
# cases land the decimal way (1.005e0 is 1.00499.. in f64, rounds to 1.01);
# TRUNC of a double stays in the modf domain. A non-integer places argument
# is accepted (rounded to a whole count), and a round-up past the operand
# width is the engine's numeric overflow.
for e in "ROUND(1.005e0,2)" "ROUND(1.015e0,2)" "ROUND(0.285e0,2)" "ROUND(2.675e0,2)" \
         "ROUND(-1.005e0,2)" "TRUNC(3.789e0,2)" "TRUNC(-3.789e0,2)" "TRUNC(1234.9e0,-2)" \
         "ROUND(3.14159,2.7)" "ROUND(3.14159,1.0)" "ROUND(3.14159,CAST(2 AS DOUBLE PRECISION))" \
         "ROUND(9223372036854775807,-1)" "TRUNC(9223372036854775807,-1)"; do
    check "approx-round / places-arg / overflow: $e" \
        "$(eof "127.0.0.1/$PORT:$A" "$e")" "$(eof "127.0.0.1/$REAL:$B" "$e")"
done

# CEILING keeps its own column name (not folded to CEIL).
cat > "$D/n.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT CEILING(1), CEIL(1) FROM RDB$DATABASE;
SQL
nof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/n.sql" 2>&1 | grep -iE "name:" | norm; }
check "CEILING and CEIL each keep their own column name" \
    "$(nof "127.0.0.1/$PORT:$A")" "$(nof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
