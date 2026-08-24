#!/bin/bash
# The DOUBLE-PRECISION math built-ins - the transcendental family that
# answers a 64-bit float: SQRT, POWER, EXP, LN, LOG10, LOG(base,x), PI()
# (a zero-argument constant), the trig SIN / COS / TAN / COT / ASIN / ACOS
# / ATAN / ATAN2, and the hyperbolic SINH / COSH / TANH. Each rounds its
# operands to f64 and calls Rust's own libm, which - on this glibc host -
# answers bit-for-bit what the engine's C libm answers, so the printed
# 17-digit DOUBLE matches to the last place.
#
# The result TYPE is DOUBLE PRECISION (sqltype 480, len 8) for every one,
# whatever the argument types (an INTEGER, a NUMERIC or a DOUBLE operand
# all promote), and NULL propagates.
#
# The domain errors match byte for byte too - the engine raises
# "expression evaluation not supported" with a trailing argument line, and
# fc raises the same code with the same function name spliced in:
#   SQRT of a negative        -> "Argument for SQRT must be zero or positive"
#   LN / LOG10 of <= 0        -> "Argument for @ must be positive"
#   LOG of a base <= 0        -> "Base for LOG must be positive"
#   LOG of a value <= 0       -> "Argument for LOG must be positive"
#   ASIN / ACOS outside [-1,1]-> "Argument for @ must be in the range [-1, 1]"
#   COT of zero               -> "Argument for COT must be different than zero"
#
# Covered (fc vs the live engine): the values over literals, INTEGER /
# NUMERIC / DOUBLE columns and a NULL row; PI() bare; nesting; the function
# in a WHERE predicate; each domain error; and the SQLDA describe (DOUBLE)
# byte for byte.
#
# Boundaries (recorded):
# - A DECFLOAT or INT128 operand: the engine computes these in the DECIMAL128
#   domain and answers a 34-significant-digit DECFLOAT (SQRT(CAST(2 AS
#   DECFLOAT)) = 1.414213562373095048801688724209698). fc has no decimal128
#   transcendental math (its decfloat module is add/sub/mul/div/round only),
#   so it REFUSES at prepare rather than ship an f64-rounded answer - a
#   separate decimal-math slice.
# - The EXACT-rounding family - CEIL / CEILING / FLOOR / ROUND / TRUNC - is
#   NOT here; those answer an exact numeric whose scale, integer width and
#   NUMERIC sub-type the engine derives from the operand (SMALLINT ceils one
#   step up to INTEGER, ROUND keeps its type, a two-arg ROUND keeps the
#   operand scale). That needs describe to carry scale and sub-type, which
#   int_func_form does not yet, so it is a separate slice.
#
#   qa/serve-real-math.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4947}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-math-crab.fdb"; B="$D/fc-math-engine.fdb"
LOG="/tmp/fc-serve-math-$PORT.log"
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

SET='CREATE TABLE T(ID INTEGER, N NUMERIC(10,4), D DOUBLE PRECISION);
INSERT INTO T VALUES (1, 2.0000, 2.0);
INSERT INTO T VALUES (2, 0.5000, 0.5);
INSERT INTO T VALUES (3, NULL, NULL);
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

cat > "$D/v.sql" <<'SQL'
SET LIST ON;
SELECT SQRT(2) A, POWER(2,10) B, EXP(1) C, LN(10) D, LOG10(1000) E, LOG(2,8) F, PI() G FROM RDB$DATABASE;
SELECT SIN(1) A, COS(1) B, TAN(1) C, COT(1) D, ATAN(1) E, ATAN2(1,1) F FROM RDB$DATABASE;
SELECT ASIN(0.5) A, ACOS(0.5) B, SINH(1) C, COSH(1) D, TANH(1) E FROM RDB$DATABASE;
SELECT SQRT(2)+POWER(2,3) A, LN(EXP(5)) B, POWER(SIN(1),2)+POWER(COS(1),2) C FROM RDB$DATABASE;
SQL
vof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/v.sql" 2>&1 | norm; }
check "transcendental values (literals, nested, PI)" \
    "$(vof "127.0.0.1/$PORT:$A")" "$(vof "127.0.0.1/$REAL:$B")"

cat > "$D/c.sql" <<'SQL'
SET LIST ON;
SELECT ID, SQRT(N) A, POWER(D,2) B, LN(N) C, SIN(D) E FROM T ORDER BY ID;
SELECT ID FROM T WHERE SQRT(N) > 1 ORDER BY ID;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/c.sql" 2>&1 | norm; }
check "over INTEGER/NUMERIC/DOUBLE columns (with a NULL row) and in WHERE" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

cat > "$D/d.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT SQRT(2), POWER(2,10), PI(), SIN(1), LOG(2,8), ATAN2(1,1) FROM RDB$DATABASE;
SELECT SQRT(N), EXP(D), LN(ID) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/d.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe is DOUBLE (sqltype 480, len 8) everywhere" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# Domain errors - each raises "expression evaluation not supported" with the
# function name spliced into the trailing argument line, byte for byte.
eof() { echo "SELECT $2 N FROM RDB\$DATABASE;" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
for e in "SQRT(-1)" "LN(0)" "LN(-5)" "LOG10(0)" "LOG(-2,8)" "LOG(2,-8)" \
         "ASIN(2)" "ACOS(-3)" "COT(0)"; do
    check "domain error: $e" \
        "$(eof "127.0.0.1/$PORT:$A" "$e")" "$(eof "127.0.0.1/$REAL:$B" "$e")"
done

# POWER's own two domain refusals: a zero base with a negative exponent, and
# a negative base with a non-integral exponent (the engine treats an
# APPROXIMATE exponent as non-integral, so a DOUBLE exponent refuses even
# when its value is whole; an exact integral one computes).
for e in "POWER(0,-1)" "POWER(0,-2)" "POWER(0.0,-1)" \
         "POWER(-2,0.5)" "POWER(-8,0.3333)" \
         "POWER(-2,CAST(2 AS DOUBLE PRECISION))" \
         "POWER(0,0)" "POWER(-2,2)" "POWER(-2,3)" \
         "POWER(CAST(-2 AS DOUBLE PRECISION),3)"; do
    check "POWER domain / boundary: $e" \
        "$(eof "127.0.0.1/$PORT:$A" "$e")" "$(eof "127.0.0.1/$REAL:$B" "$e")"
done

# Floating-point overflow: an infinite result raises 22003. EXP and POWER
# raise the plain exception_float_overflow ("Floating-point overflow.  The
# exponent ..."); the std-math family SINH / COSH raises the NAMED
# sysf_fp_overflow ("Floating point overflow in built-in function @1"). fc
# matches both vectors, function name included.
for e in "POWER(10,400)" "POWER(1E300,2)" "EXP(1000)" "EXP(710)" \
         "SINH(1000)" "COSH(1000)" "COSH(-1000)"; do
    check "float overflow: $e" \
        "$(eof "127.0.0.1/$PORT:$A" "$e")" "$(eof "127.0.0.1/$REAL:$B" "$e")"
done

# A TEXT operand: the engine describes DOUBLE and converts the string to a
# double at run time by its numeric grammar (leading / trailing blanks
# trimmed), raising 22018 "conversion error from string" when it is not a
# number. fc follows - value AND the conversion error byte for byte.
for e in "SQRT('4')" "SIN('1')" "POWER('2','3')" "EXP('1')" "COS('0')" \
         "SQRT('  9  ')" "SQRT('abc')" "LN('foo')"; do
    check "text operand: $e" \
        "$(eof "127.0.0.1/$PORT:$A" "$e")" "$(eof "127.0.0.1/$REAL:$B" "$e")"
done

# Storing a FRACTIONAL literal into an approximate column - the fix that
# went in beside these functions: a scaled decimal (2.5 arrives as
# Int(25, scale -1)) now converts to f64 the way CVT does, where the old
# `scale == 0` guard refused every non-integer and silently stored no row.
# Round-trip DOUBLE and FLOAT, positive / negative / many-digit / integral.
SETF='CREATE TABLE F(ID INTEGER, D DOUBLE PRECISION, R FLOAT);
INSERT INTO F VALUES (1, 2.5, 2.5);
INSERT INTO F VALUES (2, 0.1, 0.1);
INSERT INTO F VALUES (3, -3.14159, -3.14159);
INSERT INTO F VALUES (4, 12345.6789, 12345.6789);
INSERT INTO F VALUES (5, 100, 100);
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETF" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETF" >/dev/null 2>&1
cat > "$D/f.sql" <<'SQL'
SET LIST ON;
SELECT ID, D, R FROM F ORDER BY ID;
SQL
fof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/f.sql" 2>&1 | norm; }
check "fractional literals round-trip into DOUBLE / FLOAT columns" \
    "$(fof "127.0.0.1/$PORT:$A")" "$(fof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
