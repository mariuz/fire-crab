#!/bin/bash
# RESULT TYPING FOR WIDE NUMERICS: INT128 / NUMERIC(38) / DECFLOAT INTO
# THE DblDec FUNCTIONS, THE STATISTICAL FOLDS, ABS, DECODE, AND THE
# DOUBLE -> INT128 CONVERSION.
#
# Measured on engine 2182 and matched:
#
#   * SQRT / POWER / EXP / LN / LOG / LOG10 over an INT128-backed or
#     DECFLOAT argument, with no approximate one, compute in DECIMAL128
#     through decNumber's own routines and describe DECFLOAT(34)
#     (SysFunction.cpp makeDblDecResult / evlPower etc.); this server
#     answered a DOUBLE.  The engine's EXP is `e ** x` over a 34-digit e,
#     so EXP(100) ends ...579964E+43, not the true ...580014;
#   * PERCENTILE_CONT and the two-argument CORR / COVAR / REGR folds over
#     such a FIRST argument fold in decimal128 and describe DECFLOAT(34)
#     (this described DOUBLE or refused); VAR / STDDEV / PERCENTILE_DISC
#     over a DECFLOAT EXPRESSION refused;
#   * ABS widens SMALLINT -> INTEGER and INTEGER -> BIGINT for a cast and
#     a literal too (only a column did), reads a TEXT as DOUBLE, keeps a
#     DECFLOAT, and SUM over it widens from THAT (SUM(ABS(<INTEGER>)) is
#     INT128 - this said INT64); a simple CASE / DECODE describes NULLABLE
#     whatever its branches;
#   * a DOUBLE converted to an INT128-backed exact at RUN TIME takes the
#     engine's Int128::set(double) - defect included - so a double column
#     holding 1e30 casts to 999999999994923055729694736384; a literal under
#     an assignment to the target (a projection, an INSERT) is re-read from
#     its text and exact, but in a UNION branch or an aggregate argument it
#     is the double.  And a literal `1e37` IS the engine's double: one ULP
#     above the nearest (cvt.cpp's own text-to-double).
#
# RECORDED, not fixed: a windowed decimal fold (`VAR_POP(I) OVER ()`), a
# DECFLOAT / INT128 percentile fraction, a CAST of a double literal to
# DECFLOAT, DECODE with a mistyped search value (the engine describes and
# raises at fetch; this refuses), and a VIEW's literal cast (the engine
# runs the double conversion there too).
#
# Usage: qa/serve-real-widenum.sh [port]   (default 5890)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5890}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/widenum-eng.fdb"; FC="$D/widenum-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE FX (ID INTEGER, I INT128, N NUMERIC(38,2), D DECFLOAT(16), D34 DECFLOAT(34), DBL DOUBLE PRECISION, NN INT128 NOT NULL, B BIGINT);
INSERT INTO FX VALUES (1, 5, 2.00, 16, 2, 2.0, 7, 3);
INSERT INTO FX VALUES (2, NULL, NULL, NULL, NULL, NULL, 9, NULL);
CREATE TABLE BIG2 (ID INTEGER, M NUMERIC(38,0), I INT128, DF DECFLOAT(16), D34 DECFLOAT(34), N9 NUMERIC(9,2), N18 NUMERIC(18,2), B BIGINT, DBL DOUBLE PRECISION, S SMALLINT);
INSERT INTO BIG2 VALUES (1, 1, 1, 1, 1, 1.5, 1.5, 1, 1.0, 1);
INSERT INTO BIG2 VALUES (2, 2, 2, 2, 2, 2.5, 2.5, 2, 2.0, 2);
INSERT INTO BIG2 VALUES (3, 4, 4, 4, 4, 4.5, 4.5, 4, 4.0, 4);
INSERT INTO BIG2 VALUES (4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
CREATE TABLE BIG0 (ID INTEGER, M NUMERIC(38,0), I INT128, DF DECFLOAT(16), D34 DECFLOAT(34));
CREATE TABLE T (I INTEGER, B BIGINT, S SMALLINT, N NUMERIC(9,2), N18 NUMERIC(18,2), I128 INT128, DBL DOUBLE PRECISION, FLT FLOAT, DF DECFLOAT(16), NN INTEGER NOT NULL, V VARCHAR(5), N41 NUMERIC(4,1));
INSERT INTO T VALUES (10, 20, 3, 1.5, 2.5, 7, -1.5, -2.5, -3.5, 4, '5', -1.5);
INSERT INTO T VALUES (-10, -20, -3, -1.5, -2.5, -7, 1.5, 2.5, 3.5, 4, '-5', 1.5);
CREATE TABLE DD (ID INTEGER, D DOUBLE PRECISION, F FLOAT);
INSERT INTO DD VALUES (1, 1e30, 1e30);
INSERT INTO DD VALUES (2, 1e20, 1e20);
INSERT INTO DD VALUES (3, 1e25, 1e25);
INSERT INTO DD VALUES (5, 18446744073709551616, 18446744073709551616);
INSERT INTO DD VALUES (7, 1e18, 1e18);
INSERT INTO DD VALUES (9, 123456789012345678901234567.0, 123456789012345678901234567.0);
INSERT INTO DD VALUES (10, -1e30, -1e30);
INSERT INTO DD VALUES (11, 1e37, 1e37);
INSERT INTO DD VALUES (14, 2.5, 2.5);
INSERT INTO DD VALUES (17, 18446744073709555712, 18446744073709555712);
INSERT INTO DD VALUES (21, -1e25, -1e25);
INSERT INTO DD VALUES (26, NULL, NULL);
CREATE VIEW V1 AS SELECT CAST(1e30 AS NUMERIC(38,6)) X FROM RDB$DATABASE;
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/widenum-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/widenum-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/widenum-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-widenum-$PORT.log" 2>&1 & srv=$!
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
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the same describe, pinned
dpin() { # <label> <select> <engine-describe>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ed" != "$3" ]; then echo "FAIL $1 - THE ENGINE DESCRIBES [$ed], not the pinned [$3]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# the engine answers (pinned) and this server REFUSES - recorded
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "${fv#*SQLSTATE = 42000}" = "$fv" ]; then echo "FAIL $1 - this server no longer refuses: [$fv]; promote the cell"; fail=1
    else echo "OK   $1 (recorded: the engine answers [${ev:0:80}], this server refuses)"; fi
}
# both answer, DIFFERENTLY - recorded (the engine pinned)
differs() { # <label> <script> <engine-output> <fc-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server answers [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server [${fv:0:60}])"; fi
}
DUAL='FROM RDB$DATABASE'
D34='01: sqltype: 32762 DECFLOAT(34) scale: 0 subtype: 0 len: 16'
D34N='01: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16'
DBL='01: sqltype: 480 DOUBLE scale: 0 subtype: 0 len: 8'
DBLN='01: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8'
EVAL='Statement failed, SQLSTATE = 42000|expression evaluation not supported'
E22003='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'

echo "--- 1. THE DblDec FUNCTIONS OVER INT128 / NUMERIC(38) / DECFLOAT: DECFLOAT(34), decNumber's digits"
dpin "1 POWER(<INT128>, 30) describes DECFLOAT(34)" "SELECT POWER(CAST(10 AS INT128), 30) $DUAL;" "$D34"
pin  "1 ...and answers the exact power" "SELECT POWER(CAST(10 AS INT128), 30) $DUAL;" "POWER|1000000000000000000000000000000"
pin  "1 EXP(<INT128> 1) is the engine's 34-digit e" "SELECT EXP(CAST(1 AS INT128)) $DUAL;" "EXP|2.718281828459045235360287471352662"
pin  "1 EXP(100) is e ** 100 over that e (not exp(100))" "SELECT EXP(CAST(100 AS INT128)) $DUAL;" "EXP|2.688117141816135448412625551579964E+43"
pin  "1 SQRT / LN over NUMERIC(38,0) and INT128" "SELECT SQRT(CAST(2 AS NUMERIC(38,0))), LN(CAST(10 AS INT128)) $DUAL;" "SQRT LN|1.414213562373095048801688724209698 2.302585092994045684017991454684364"
pin  "1 POWER keeps the operand cohort: 10.00 ** 3 is 1000.000000" "SELECT POWER(CAST(10 AS NUMERIC(38,2)), 3) $DUAL;" "POWER|1000.000000"
pin  "1 an INT128 EXPONENT decides too" "SELECT POWER(10, CAST(3 AS INT128)), POWER(CAST(2 AS BIGINT), CAST(3 AS INT128)) $DUAL;" "POWER POWER|1000 8"
pin  "1 CONTROL a BIGINT base and an INTEGER exponent stay DOUBLE" "SELECT POWER(CAST(2 AS BIGINT), 10) $DUAL;" "POWER|1024.000000000000"
dpin "1 ...described DOUBLE" "SELECT POWER(CAST(2 AS BIGINT), 10) $DUAL;" "$DBL"
pin  "1 DECFLOAT(16) and (34) arguments" "SELECT SQRT(CAST(2 AS DECFLOAT(16))), EXP(CAST(1 AS DECFLOAT(16))), SQRT(CAST(2 AS DECFLOAT(34))) $DUAL;" "SQRT EXP SQRT|1.414213562373095048801688724209698 2.718281828459045235360287471352662 1.414213562373095048801688724209698"
pin  "1 LOG / LOG10: an exact division is short, an inexact one 34 digits" "SELECT LOG(CAST(10 AS INT128), 100), LOG10(CAST(1000 AS INT128)), LOG(CAST(10 AS INT128), CAST(1000 AS INT128)), LOG(CAST(2 AS INT128), 10) $DUAL;" "LOG LOG10 LOG LOG|2 3 3.000000000000000000000000000000000 3.321928094887362347870319429489390"
pin  "1 CONTROL SIN / FLOOR / ABS / SIGN / MOD over INT128 keep their own types" "SELECT SIN(CAST(1 AS INT128)), FLOOR(CAST(1 AS INT128)), ABS(CAST(-1 AS INT128)), SIGN(CAST(-1 AS INT128)), MOD(CAST(10 AS INT128), 3) $DUAL;" "SIN FLOOR ABS SIGN MOD|0.8414709848078965 1 1 -1 1"
pin  "1 over columns: nullability follows the operand" "SELECT SQRT(I), SQRT(NN), POWER(NN, 2), POWER(I, NN), EXP(D), LN(N), LOG(NN, D34), LOG10(NN) FROM FX ORDER BY ID;" "SQRT SQRT POWER POWER EXP LN LOG LOG10|2.236067977499789696409173668731276 2.645751311064590590501615753639260 49 78125 8886110.520507872636763023740781424 0.6931471805599453094172321214581766 0.3562071871080221765141770780012905 0.8450980400142568307122162585926362|<null> 3 81 <null> <null> <null> <null> 0.9542425094393248745900558065102306"
dpin "1 ...SQRT(<NOT NULL INT128>) describes NOT nullable" "SELECT SQRT(NN), SQRT(I) FROM FX;" "$D34|02: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16"
pin  "1 an APPROXIMATE argument wins: DOUBLE" "SELECT POWER(I, 2.5e0), POWER(DBL, I) FROM FX WHERE ID = 1;" "POWER POWER|55.90169943749474 32.00000000000000"
dpin "1 ...described DOUBLE beside a decimal sibling" "SELECT POWER(I, 2.5e0), POWER(I, D), LOG(I, 8), LOG(2, I) FROM FX WHERE ID = 1;" "$DBLN|02: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16|03: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16|04: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16"
pin  "1 ...their values" "SELECT POWER(I, D), POWER(B, I), LOG(I, 8), LOG(2, I) FROM FX WHERE ID = 1;" "POWER POWER LOG LOG|152587890625 243 1.292029674220179152010319706291897 2.321928094887362347870319429489391"
pin  "1 NULL propagates" "SELECT SQRT(CAST(NULL AS INT128)), POWER(I, NULL), POWER(NULL, I) FROM FX WHERE ID = 1;" "SQRT POWER POWER|<null> <null> <null>"
pin  "1 SQRT of a negative INT128 is the domain refusal" "SELECT SQRT(CAST(-1 AS INT128)) $DUAL;" "SQRT|$EVAL|-Argument for SQRT must be zero or positive"
pin  "1 LN of zero / negative" "SELECT LN(CAST(0 AS INT128)) $DUAL;" "LN|$EVAL|-Argument for LN must be positive"
pin  "1 LOG: base first, then the argument" "SELECT LOG(CAST(-2 AS INT128), 10) $DUAL;" "LOG|$EVAL|-Base for LOG must be positive"
pin  "1 LOG(1, x) divides by ln(1): the decimal divide by zero" "SELECT LOG(CAST(1 AS INT128), 10) $DUAL;" "LOG|Statement failed, SQLSTATE = 22012|Decimal float divide by zero. The code attempted to divide a DECFLOAT value by zero."
pin  "1 0 ** -1 is an untrapped Infinity" "SELECT POWER(CAST(0 AS INT128), -1) $DUAL;" "POWER|Infinity"
pin  "1 a negative base to a fractional power is invalid" "SELECT POWER(CAST(-2 AS INT128), 0.5) $DUAL;" "POWER|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation."
pin  "1 0 ** 0 too" "SELECT POWER(CAST(0 AS INT128), 0) $DUAL;" "POWER|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation."
pin  "1 ...but an odd integer power keeps the sign" "SELECT POWER(CAST(-2 AS INT128), 3) $DUAL;" "POWER|-8"
pin  "1 the decimal128 overflow: 10 ** 6145" "SELECT POWER(CAST(10 AS INT128), 6145) $DUAL;" "POWER|Statement failed, SQLSTATE = 22003|Decimal float overflow. The exponent of a result is greater than the magnitude allowed."
pin  "1 ...and 10 ** 6144 fits, clamped" "SELECT POWER(CAST(10 AS INT128), 6144) $DUAL;" "POWER|1.000000000000000000000000000000000E+6144"
pin  "1 EXP far out: no overflow at 10000, tiny at -10000" "SELECT EXP(CAST(10000 AS INT128)), EXP(CAST(-10000 AS INT128)) $DUAL;" "EXP EXP|8.806818225662921587261496007628434E+4342 1.135483865314736098540938875068328E-4343"
pin  "1 34 digits exactly, then rounding into E form" "SELECT POWER(CAST(2 AS INT128), 100), POWER(CAST(2 AS INT128), 120), POWER(CAST(10 AS INT128), 33), POWER(CAST(10 AS INT128), 34) $DUAL;" "POWER POWER POWER POWER|1267650600228229401496703205376 1.329227995784915872903807060280345E+36 1000000000000000000000000000000000 1.000000000000000000000000000000000E+34"
pin  "1 fractional exponents: exp(ln(x) * y) at 44 digits" "SELECT POWER(CAST(2.5 AS NUMERIC(38,1)), 3), POWER(CAST(7 AS INT128), CAST(2.5 AS NUMERIC(38,1))), POWER(CAST(1.1 AS DECFLOAT(16)), 100), POWER(CAST(16 AS DECFLOAT(16)), 0.5) $DUAL;" "POWER POWER POWER POWER|15.625 129.6418142421649389345791719283238 13780.61233982227018411833717208964 4.000000000000000000000000000000000"
pin  "1 SQRT: an exact root trims to the ideal exponent" "SELECT SQRT(CAST(16 AS INT128)), SQRT(CAST(100 AS NUMERIC(38,2))), SQRT(CAST(0 AS INT128)), SQRT(CAST(123456789012345678901234567890123 AS INT128)) $DUAL;" "SQRT SQRT SQRT SQRT|4 10.0 0 11111111061111110.99361111058186109"
pin  "1 LN of 2.00 takes the Newton loop, LN(2) the constant - same digits" "SELECT LN(CAST(2 AS NUMERIC(38,2))), LN(CAST(2 AS INT128)), LN(CAST(1 AS INT128)), LN(CAST(123456789012345678901234567890 AS INT128)) $DUAL;" "LN LN LN LN|0.6931471805599453094172321214581766 0.6931471805599453094172321214581766 0 66.98568871914297739757675389633419"
pin  "1 EXP over NUMERIC(38,1) and negative" "SELECT EXP(CAST(0 AS INT128)), EXP(CAST(2 AS NUMERIC(38,1))), EXP(CAST(-1 AS INT128)) $DUAL;" "EXP EXP EXP|1 7.389056098930650227230427460575005 0.3678794411714423215955237701614609"
pin  "1 the result in arithmetic, a CAST, a compare, a fold" "SELECT SQRT(I) + 1, CAST(SQRT(I) AS NUMERIC(18,6)), SQRT(I) * I, SQRT(I) > 2 FROM FX WHERE ID = 1;" "ADD CAST MULTIPLY BOOL|3.236067977499789696409173668731276 2.236068 11.18033988749894848204586834365638 <true>"
pin  "1 SUM / AVG / MAX over it are DECFLOAT(34)" "SELECT SUM(SQRT(I)), AVG(POWER(I, 2)), MAX(EXP(D34)) FROM FX;" "SUM AVG MAX|2.236067977499789696409173668731276 25 7.389056098930650227230427460575005"
dpin "1 ...described so" "SELECT SUM(SQRT(I)), AVG(POWER(I, 2)), MAX(EXP(D34)) FROM FX;" "$D34N|02: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16|03: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16"

echo "--- 2. THE STATISTICAL FOLDS AND PERCENTILE_CONT OVER INT128 / DECFLOAT: DECFLOAT(34)"
dpin "2 PERCENTILE_CONT over NUMERIC(38,0) describes DECFLOAT(34) nullable" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY M) FROM BIG2;" "$D34N"
pin  "2 ...its value, and over INT128 / DECFLOAT(16) / DECFLOAT(34)" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY M), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY I), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DF), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY D34) FROM BIG2;" "PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT|2 2 2 2"
pin  "2 CONTROL over NUMERIC(9,2) / BIGINT / DOUBLE / SMALLINT it is a DOUBLE" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY N9), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY B), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DBL), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY S) FROM BIG2;" "PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT|2.500000000000000 2.000000000000000 2.000000000000000 2.000000000000000"
pin  "2 a fractional rank interpolates through the 17-digit double weights" "SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY I), PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY I), PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY I), PERCENTILE_CONT(0) WITHIN GROUP (ORDER BY I), PERCENTILE_CONT(1) WITHIN GROUP (ORDER BY I), PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY DF) FROM BIG2;" "PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT|1.50000000000000000 3.00000000000000000 1.19999999999999996 1 4 1.19999999999999996"
pin  "2 ...the DOUBLE fold prints 1.200000000000000 beside a decimal one" "SELECT PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY DBL), PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY B), PERCENTILE_CONT(1.0/3) WITHIN GROUP (ORDER BY I) FROM BIG2;" "PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_CONT|1.200000000000000 1.200000000000000 1.60000000000000009"
pin  "2 PERCENTILE_DISC keeps the order value's type" "SELECT PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY M), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY DF), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY D34), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY N9) FROM BIG2;" "PERCENTILE_DISC PERCENTILE_DISC PERCENTILE_DISC PERCENTILE_DISC|2 2 2 2.50"
dpin "2 ...described: INT128 sub_type 1, DECFLOAT(16), DECFLOAT(34), LONG" "SELECT PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY M), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY DF), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY D34), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY N9) FROM BIG2;" "01: sqltype: 32752 INT128 Nullable scale: 0 subtype: 1 len: 16|02: sqltype: 32760 DECFLOAT(16) Nullable scale: 0 subtype: 0 len: 8|03: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16|04: sqltype: 496 LONG Nullable scale: -2 subtype: 1 len: 4"
pin  "2 an EXPRESSION order: a CAST to INT128 / DECFLOAT, arithmetic" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(ID AS INT128)), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY I + 1), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY CAST(ID AS DECFLOAT(16))), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY I * 2), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(ID AS DECFLOAT(34))) FROM BIG2;" "PERCENTILE_CONT PERCENTILE_CONT PERCENTILE_DISC PERCENTILE_DISC PERCENTILE_CONT|2.50000000000000000 3 2 4 2.50000000000000000"
dpin "2 ...described" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(ID AS INT128)), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY CAST(ID AS DECFLOAT(16))), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY I * 2) FROM BIG2;" "$D34N|02: sqltype: 32760 DECFLOAT(16) Nullable scale: 0 subtype: 0 len: 8|03: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16"
pin  "2 DESC orders" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY I DESC), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY M DESC), PERCENTILE_CONT(0.3) WITHIN GROUP (ORDER BY I DESC) FROM BIG2;" "PERCENTILE_CONT PERCENTILE_DISC PERCENTILE_CONT|2 2 2.79999999999999982"
pin  "2 VAR / STDDEV over a DECFLOAT EXPRESSION (refused): the engine's STDDEV_POP is the variance" "SELECT STDDEV_POP(CAST(ID AS DECFLOAT(16))), VAR_POP(CAST(ID AS DECFLOAT(34))), STDDEV_SAMP(DF + 1), VAR_POP(I * 2), VAR_POP(CAST(ID AS INT128)), VAR_SAMP(M + M) FROM BIG2;" "STDDEV_POP VAR_POP STDDEV_SAMP VAR_POP VAR_POP VAR_SAMP|1.25 1.25 1.527525231651946668862682397909337 6.222222222222222222222222222222223 1.25 9.333333333333333333333333333333335"
dpin "2 ...DECFLOAT(34) NOT nullable" "SELECT STDDEV_POP(CAST(ID AS DECFLOAT(16))), VAR_SAMP(M + M) FROM BIG2;" "$D34|02: sqltype: 32762 DECFLOAT(34) scale: 0 subtype: 0 len: 16"
pin  "2 the two-argument folds: the FIRST argument types them" "SELECT CORR(ID, M), CORR(M, ID), COVAR_POP(ID, M), COVAR_POP(M, ID), COVAR_SAMP(M, ID), COVAR_SAMP(ID, M), REGR_SLOPE(ID, M), REGR_INTERCEPT(M, ID), REGR_R2(ID, I) FROM BIG2;" "CORR CORR COVAR_POP COVAR_POP COVAR_SAMP COVAR_SAMP REGR_SLOPE REGR_INTERCEPT REGR_R2|0.9819805060619656 0.9819805060619657156974386843702867 1.000000000000000 1 1.5 1.500000000000000 0.6428571428571427 -0.666666666666666666666666666666667 0.9642857142857141"
dpin "2 ...DOUBLE / DECFLOAT(34) by that argument, none nullable" "SELECT CORR(ID, M), CORR(M, ID), COVAR_SAMP(M, ID), REGR_R2(ID, I) FROM BIG2;" "$DBL|02: sqltype: 32762 DECFLOAT(34) scale: 0 subtype: 0 len: 16|03: sqltype: 32762 DECFLOAT(34) scale: 0 subtype: 0 len: 16|04: sqltype: 480 DOUBLE scale: 0 subtype: 0 len: 8"
pin  "2 REGR_AVGX / AVGY / SXX / SXY / SYY / COUNT both ways round" "SELECT REGR_AVGX(M, ID), REGR_AVGY(ID, M), REGR_SXX(M, ID), REGR_SXY(ID, M), REGR_SYY(M, ID), REGR_COUNT(M, ID), REGR_AVGX(ID, M), REGR_AVGY(M, ID), REGR_SXX(ID, M) FROM BIG2;" "REGR_AVGX REGR_AVGY REGR_SXX REGR_SXY REGR_SYY REGR_COUNT REGR_AVGX REGR_AVGY REGR_SXX|2 2.000000000000000 2 3.000000000000000 4.66666666666666666666666666666667 3 2.333333333333333 2.333333333333333333333333333333333 4.666666666666668"
pin  "2 a DOUBLE second argument converts at 17 digits; a DECFLOAT first one decides" "SELECT CORR(DBL, M), CORR(M, DBL), CORR(DF, ID), CORR(ID, DF), CORR(D34, DF), COVAR_POP(DF, I), REGR_SLOPE(DBL, I), REGR_SXY(I, DBL), REGR_AVGX(I, DBL) FROM BIG2;" "CORR CORR CORR CORR CORR COVAR_POP REGR_SLOPE REGR_SXY REGR_AVGX|1.000000000000000 1 0.9819805060619657156974386843702867 0.9819805060619656 1 1.555555555555555555555555555555557 1.000000000000000 4.66666666666666666666666666666667 2.333333333333333333333333333333333"
pin  "2 REGR_SLOPE / INTERCEPT / AVGY / R2 over INT128 and the NUMERIC(9,2) controls" "SELECT REGR_SLOPE(M, ID), REGR_INTERCEPT(ID, M), REGR_AVGY(M, ID), REGR_R2(M, M), REGR_SXX(N9, ID), COVAR_POP(N18, B), CORR(B, N18), CORR(S, S) FROM BIG2;" "REGR_SLOPE REGR_INTERCEPT REGR_AVGY REGR_R2 REGR_SXX COVAR_POP CORR CORR|1.500000000000000000000000000000000 0.5000000000000002 2.333333333333333333333333333333333 1 2.000000000000000 1.555555555555556 1.000000000000000 1.000000000000000"
pin  "2 an EMPTY set: NULL percentiles, the not-null folds' zero" "SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY I), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY I), VAR_POP(I), STDDEV_SAMP(D34), CORR(M, ID), COVAR_POP(I, I), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DF) FROM BIG0;" "PERCENTILE_CONT PERCENTILE_DISC VAR_POP STDDEV_SAMP CORR COVAR_POP PERCENTILE_CONT|<null> <null> 0E-6176 0E-6176 0E-6176 0E-6176 <null>"
pin  "2 CONTROL AVG / SUM keep their own widening" "SELECT AVG(I), SUM(I), AVG(M), SUM(M), AVG(DF), SUM(D34) FROM BIG2;" "AVG SUM AVG SUM AVG SUM|2 7 2 7 2.333333333333333 7"
pin  "2 grouped" "SELECT ID, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY I), CORR(M, ID) FROM BIG2 GROUP BY ID ORDER BY ID;" "ID PERCENTILE_CONT CORR|1 1 0E-6176|2 2 0E-6176|3 4 0E-6176|4 <null> 0E-6176"

echo "--- 3. ABS AND DECODE: the widening, the nullability, the SUM over them"
dpin "3 ABS widens SMALLINT -> LONG, INTEGER -> INT64, keeps BIGINT / NUMERIC(18) / INT128 / DOUBLE / FLOAT / DECFLOAT(16)" "SELECT ABS(S), ABS(I), ABS(B), ABS(N), ABS(N18), ABS(I128), ABS(DBL), ABS(FLT), ABS(DF), ABS(N41), ABS(NN) FROM T;" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|02: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|03: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|04: sqltype: 580 INT64 Nullable scale: -2 subtype: 0 len: 8|05: sqltype: 580 INT64 Nullable scale: -2 subtype: 1 len: 8|06: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|07: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8|08: sqltype: 482 FLOAT Nullable scale: 0 subtype: 0 len: 4|09: sqltype: 32760 DECFLOAT(16) Nullable scale: 0 subtype: 0 len: 8|10: sqltype: 496 LONG Nullable scale: -1 subtype: 0 len: 4|11: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8"
pin  "3 ...their values (ABS of a DECFLOAT refused)" "SELECT ABS(S), ABS(I), ABS(B), ABS(N), ABS(N18), ABS(I128), ABS(DBL), ABS(FLT), ABS(DF), ABS(N41), ABS(NN) FROM T;" "ABS ABS ABS ABS ABS ABS ABS ABS ABS ABS ABS|3 10 20 1.50 2.50 7 1.500000000000000 2.5000000 3.5 1.5 4|3 10 20 1.50 2.50 7 1.500000000000000 2.5000000 3.5 1.5 4"
dpin "3 a literal, NULL, a TEXT (DOUBLE), a CAST: the same one-step widening" "SELECT ABS(1), ABS(1.5), ABS(NULL), ABS('5'), ABS(V), ABS(CAST(1.5 AS NUMERIC(4,1))), ABS(CAST(-100000 AS NUMERIC(9,3))), ABS(CAST(1 AS NUMERIC(18,4))) FROM T;" "01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|02: sqltype: 580 INT64 scale: -1 subtype: 0 len: 8|03: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|04: sqltype: 480 DOUBLE scale: 0 subtype: 0 len: 8|05: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8|06: sqltype: 496 LONG scale: -1 subtype: 0 len: 4|07: sqltype: 580 INT64 scale: -3 subtype: 0 len: 8|08: sqltype: 580 INT64 scale: -4 subtype: 1 len: 8"
pin  "3 ...their values" "SELECT ABS(1), ABS(1.5), ABS(NULL), ABS('5'), ABS(V), ABS(CAST(1.5 AS NUMERIC(4,1))), ABS(CAST(-100000 AS NUMERIC(9,3))), ABS(CAST(1 AS NUMERIC(18,4))) FROM T;" "ABS ABS ABS ABS ABS ABS ABS ABS|1 1.5 <null> 5.000000000000000 5.000000000000000 1.5 100000.000 1.0000|1 1.5 <null> 5.000000000000000 5.000000000000000 1.5 100000.000 1.0000"
dpin "3 SUM widens from what ABS answers: SUM(ABS(<INTEGER>)) is INT128" "SELECT SUM(ABS(S)), SUM(ABS(I)), SUM(ABS(B)), SUM(ABS(N)), SUM(ABS(N18)), SUM(ABS(I128)), SUM(ABS(DBL)), SUM(ABS(DF)), SUM(ABS(N41)), SUM(ABS(NN)), SUM(ABS(V)) FROM T;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|02: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|03: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|04: sqltype: 32752 INT128 Nullable scale: -2 subtype: 0 len: 16|05: sqltype: 32752 INT128 Nullable scale: -2 subtype: 1 len: 16|06: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|07: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8|08: sqltype: 32762 DECFLOAT(34) Nullable scale: 0 subtype: 0 len: 16|09: sqltype: 580 INT64 Nullable scale: -1 subtype: 0 len: 8|10: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|11: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8"
pin  "3 ...their values" "SELECT SUM(ABS(S)), SUM(ABS(I)), SUM(ABS(B)), SUM(ABS(N)), SUM(ABS(N18)), SUM(ABS(I128)), SUM(ABS(DBL)), SUM(ABS(DF)), SUM(ABS(N41)), SUM(ABS(NN)), SUM(ABS(V)) FROM T;" "SUM SUM SUM SUM SUM SUM SUM SUM SUM SUM SUM|6 20 40 3.00 5.00 14 3.000000000000000 7.0 3.0 8 10.00000000000000"
dpin "3 AVG keeps INT64; MIN / MAX / COUNT; ABS(I) / 3 is INT128" "SELECT AVG(ABS(I)), AVG(ABS(S)), AVG(ABS(N)), AVG(ABS(B)), SUM(ABS(I) + 1), MIN(ABS(I)), MAX(ABS(N)), SUM(ABS(I) * 2), COUNT(ABS(I)) FROM T;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|02: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|03: sqltype: 580 INT64 Nullable scale: -2 subtype: 0 len: 8|04: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|05: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|06: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|07: sqltype: 580 INT64 Nullable scale: -2 subtype: 0 len: 8|08: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|09: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8"
dpin "3 ...arithmetic over ABS" "SELECT ABS(I) + 1, ABS(S) * 2, ABS(N) - 1, ABS(I) / 3, -ABS(I), ABS(ABS(S)), ABS(I) + ABS(S) FROM T;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|02: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|03: sqltype: 580 INT64 Nullable scale: -2 subtype: 0 len: 8|04: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|05: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|06: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|07: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8"
pin  "3 ...and the values, grouped and windowed" "SELECT SUM(ABS(I)) FROM T GROUP BY ABS(S); SELECT SUM(ABS(I)) OVER (), AVG(ABS(B)) OVER () FROM T; SELECT ABS(I) FROM T WHERE ABS(I) > 5 ORDER BY ABS(I) DESC;" "SUM|20|SUM AVG|20 20|20 20|ABS|10|10"
pin  "3 the BIGINT minimum has no ABS" "SELECT ABS(CAST(-9223372036854775808 AS BIGINT)) $DUAL;" "ABS|$E22003"
dpin "3 a simple CASE / DECODE describes NULLABLE whatever its branches; the searched CASE / IIF follow them" "SELECT DECODE(I, 1, 'a', 'bb'), DECODE(NN, 4, 'x', 'y'), DECODE(I, 1, 'a'), CASE I WHEN 1 THEN 'a' ELSE 'bb' END, CASE NN WHEN 4 THEN 'x' ELSE 'y' END, IIF(NN = 4, 'x', 'y'), COALESCE(I, 0), DECODE(NN, 4, NN, 5) FROM T;" "01: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 2 charset: 0 SYSTEM.NONE|02: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|03: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|04: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 2 charset: 0 SYSTEM.NONE|05: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|06: sqltype: 452 TEXT scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|07: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|08: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4"
pin  "3 ...their values" "SELECT DECODE(I, 1, 'a', 'bb'), DECODE(NN, 4, 'x', 'y'), DECODE(I, 1, 'a'), CASE I WHEN 1 THEN 'a' ELSE 'bb' END, CASE NN WHEN 4 THEN 'x' ELSE 'y' END, IIF(NN = 4, 'x', 'y'), COALESCE(I, 0), DECODE(NN, 4, NN, 5) FROM T;" "DECODE DECODE DECODE CASE CASE CASE COALESCE DECODE|bb x <null> bb x x 10 4|bb x <null> bb x x -10 4"
dpin "3 ...over literals and numerics" "SELECT DECODE(1, 1, 'a', 'bb') $DUAL; SELECT DECODE(I, 10, 1, 2), DECODE(I, 10, 1.5, 2), DECODE(I, 10, 1, 2.5), DECODE(I, 10, CAST(1 AS INT128), 2) FROM T;" "01: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 2 charset: 0 SYSTEM.NONE|01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|02: sqltype: 580 INT64 Nullable scale: -1 subtype: 0 len: 8|03: sqltype: 580 INT64 Nullable scale: -1 subtype: 0 len: 8|04: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16"
pin  "3 ...and the values" "SELECT DECODE(I, 10, 1, 2), DECODE(I, 10, 1.5, 2), DECODE(I, 10, 1, 2.5), DECODE(I, 10, CAST(1 AS INT128), 2) FROM T;" "DECODE DECODE DECODE DECODE|1 1.5 1.0 1|2 2.0 2.5 2"

echo "--- 4. A DOUBLE INTO AN INT128-BACKED EXACT: the engine's Int128::set(double), defect included"
pin  "4 a DOUBLE column to NUMERIC(38,0): exact below 2^64, mangled above" "SELECT ID, CAST(D AS NUMERIC(38,0)) FROM DD ORDER BY ID;" "ID CAST|1 999999999994923055729694736384|2 99999999998338007040|3 9999999999999998758486016|5 18446744073709551616|7 1000000000000000000|9 123456789012345678152597504|10 -999999999994923055729694736384|11 10000000000000000719354278919532445696|14 3|17 18446744073709551616|21 -9999999999999998758486016|26 <null>"
pin  "4 ...to NUMERIC(38,6): scaled by 1e6 IN DOUBLE first" "SELECT ID, CAST(D AS NUMERIC(38,6)) FROM DD WHERE ID < 11 ORDER BY ID;" "ID CAST|1 1000000000000000042420637374017.961984|2 100000000000000004764.729344|3 9999999999986124045444366.467072|5 18446744073709551616.000000|7 999999999999997298.868224|9 123456789012336696855637690.155008|10 -1000000000000000042420637374017.961984"
pin  "4 ...and past the range at that scale, 22003" "SELECT CAST(D AS NUMERIC(38,6)) FROM DD WHERE ID = 11;" "CAST|$E22003"
pin  "4 a FLOAT column converts as its exact double" "SELECT ID, CAST(F AS NUMERIC(38,0)) FROM DD WHERE ID IN (1, 2, 7, 9, 11) ORDER BY ID;" "ID CAST|1 1000000015047466219876688855040|2 100000002004087734272|7 999999984306749440|9 123456790068172987402551296|11 9999999933815812510711506376257961984"
pin  "4 CAST(D AS INT128) is the same conversion; a NUMERIC(38,2) target" "SELECT ID, CAST(D AS INT128), CAST(D AS NUMERIC(38,2)) FROM DD WHERE ID IN (5, 7, 17) ORDER BY ID;" "ID CAST CAST|5 18446744073709551616 18446744073709551616.00|7 1000000000000000000 999999999983380070.40|17 18446744073709551616 18446744073709551616.00"
pin  "4 CONTROL an INT64-backed target is the plain conversion" "SELECT ID, CAST(D AS NUMERIC(18,2)), CAST(D AS BIGINT) FROM DD WHERE ID = 14; SELECT CAST(D AS NUMERIC(18,2)) FROM DD WHERE ID = 7;" "ID CAST CAST|14 2.50 3|CAST|$E22003"
pin  "4 a LITERAL under the projection is re-read from its text: exact" "SELECT CAST(1e30 AS NUMERIC(38,6)), CAST(1e30 AS NUMERIC(38,6)) + 0, COALESCE(CAST(1e30 AS NUMERIC(38,6)), 0) $DUAL;" "CAST ADD COALESCE|1000000000000000000000000000000.000000 1000000000000000000000000000000.000000 1000000000000000000000000000000.000000"
pin  "4 ...in a UNION branch it is the double (the map is no assignment)" "SELECT CAST(1e30 AS NUMERIC(38,6)) X $DUAL UNION ALL SELECT CAST(1e30 AS NUMERIC(38,6)) $DUAL;" "X|1000000000000000042420637374017.961984|1000000000000000042420637374017.961984"
pin  "4 ...whichever branch, UNION or UNION ALL, and SUM over it is exact" "SELECT 1 X $DUAL UNION ALL SELECT CAST(1e30 AS NUMERIC(38,6)) $DUAL; SELECT CAST(1e30 AS NUMERIC(38,6)) X $DUAL UNION SELECT 1 $DUAL; SELECT SUM(X) FROM (SELECT CAST(1e30 AS NUMERIC(38,6)) X $DUAL UNION ALL SELECT CAST(1e30 AS NUMERIC(38,6)) $DUAL);" "X|1.000000|1000000000000000042420637374017.961984|X|1.000000|1000000000000000042420637374017.961984|SUM|2000000000000000084841274748035.923968"
pin  "4 ...an AGGREGATE argument is the double too" "SELECT MAX(CAST(1e30 AS NUMERIC(38,6))) $DUAL;" "MAX|1000000000000000042420637374017.961984"
pin  "4 ...and a literal cast to DOUBLE first" "SELECT CAST(CAST(1e30 AS DOUBLE PRECISION) AS NUMERIC(38,6)) $DUAL;" "CAST|1000000000000000042420637374017.961984"
pin  "4 the union branch over other magnitudes (a 20-digit spelling is a DECFLOAT literal: exact)" "SELECT CAST(18446744073709555712e0 AS NUMERIC(38,0)) X $DUAL UNION ALL SELECT CAST(2e19 AS NUMERIC(38,0)) $DUAL UNION ALL SELECT CAST(1e20 AS NUMERIC(38,0)) $DUAL UNION ALL SELECT CAST(1e25 AS NUMERIC(38,0)) $DUAL UNION ALL SELECT CAST(1e30 AS NUMERIC(38,0)) $DUAL UNION ALL SELECT CAST(1e35 AS NUMERIC(38,0)) $DUAL;" "X|18446744073709555712|19999999999667601408|99999999998338007040|9999999999999998758486016|999999999994923055729694736384|99999999999999996863366107917975552"
pin  "4 ...the same double through a column and a CAST to DOUBLE: mangled" "SELECT CAST(CAST(18446744073709555712e0 AS DOUBLE PRECISION) AS NUMERIC(38,0)), CAST(CAST(2e19 AS DOUBLE PRECISION) AS NUMERIC(38,0)) $DUAL;" "CAST CAST|18446744073709551616 19999999999667601408"
pin  "4 a literal 1e37 IS the engine's double: one ULP above the nearest (its own text-to-double)" "SELECT CAST(1e37 AS NUMERIC(38,0)) X $DUAL UNION ALL SELECT CAST(1.7e38 AS NUMERIC(38,0)) $DUAL;" "X|10000000000000000719354278919532445696|170000000000000016951389224501696790528"
pin  "4 ...CONTROL the same literal projected is exact, and 1e38 overflows NUMERIC(38,6)" "SELECT CAST(1e37 AS NUMERIC(38,0)) $DUAL; SELECT CAST(1e38 AS NUMERIC(38,6)) X $DUAL UNION ALL SELECT 1 $DUAL;" "CAST|10000000000000000000000000000000000000|X|$E22003"
pin  "4 an INSERT of the literal is an assignment: exact" "INSERT INTO BIG0 (ID, M) VALUES (1, CAST(1e30 AS NUMERIC(38,0))); SELECT M FROM BIG0; ROLLBACK;" "M|1000000000000000000000000000000"
pin  "4 CAST(1e30 AS DECFLOAT(34)) in a union branch is the double's 17 digits" "SELECT CAST(1e30 AS DECFLOAT(34)) X $DUAL UNION ALL SELECT 1 $DUAL;" "X|1.0000000000000000E+30|1"

echo "--- 5. RECORDED (the engine answers; this server refuses or differs)"
refused "5 a WINDOWED decimal fold" "SELECT ID, VAR_POP(I) OVER () FROM BIG2 ORDER BY ID;" "ID VAR_POP|1 1.555555555555555555555555555555557|2 1.555555555555555555555555555555557|3 1.555555555555555555555555555555557|4 1.555555555555555555555555555555557"
refused "5 a DECFLOAT / INT128 percentile FRACTION" "SELECT PERCENTILE_CONT(CAST(0.5 AS DECFLOAT(16))) WITHIN GROUP (ORDER BY I) FROM BIG2;" "PERCENTILE_CONT|2"
refused "5 a double literal cast to DECFLOAT under the projection (the engine's text fold)" "SELECT CAST(1e30 AS DECFLOAT(34)) $DUAL;" "CAST|1E+30"
refused "5 DECODE with a mistyped search value: the engine describes, then raises at fetch" "SELECT DECODE(I, 10, 'a', 'b', 'c') FROM T;" "DECODE|a|Statement failed, SQLSTATE = 22018|conversion error from string \"b\""
differs "5 a VIEW's literal cast runs the double conversion on the engine" "SELECT X FROM V1;" "X|1000000000000000042420637374017.961984" "X|1000000000000000000000000000000.000000"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-widenum-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 72 ]; then echo "FAIL only $ran checks ran (floor 72)"; fail=1; fi
exit $fail
