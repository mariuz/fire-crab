#!/bin/bash
# BUILT-IN FUNCTION ARGUMENTS: THE ENGINE'S RANGE AND DOMAIN CHECKS.
#
# Measured on engine 2182; every cell below that is not a CONTROL
# answered differently here before:
#
#   * DATEADD: a quantity past the part's own bound raises before any
#     arithmetic and the result must stay in 0001..9999, the error naming
#     the OPERAND's family (valid dates / a valid time / valid timestamps,
#     22008). YEAR 4294967296 WRAPPED to a date here; the in-range misses
#     were a bare Dynamic SQL Error. MILLISECOND is read at scale -1 (in
#     100us units), so 0.5 ms adds .0005 - it was rounded to whole ms. A
#     DATE takes a clock amount as whole days truncated toward zero, a
#     TIME rides on the calendar's middle day, and a forward MONTH move
#     from Feb 29 into a non-leap year lands on the month's last day.
#   * every INTEGER-typed argument (LEFT/RIGHT/SUBSTRING/POSITION/LPAD/
#     RPAD lengths and starts, ROUND/TRUNC places) goes through
#     MOV_get_long: past 32 bits it is 22003, never a wrapped count. A
#     CONSTANT SUBSTRING FOR / LPAD length is read by the describe, so it
#     refuses the PREPARE - `FOR 2147483648` was described `len:
#     -2147483648` and the client dumped core.
#   * LPAD/RPAD and POSITION raise their own numbered 42000 argument
#     errors (it was SUBSTRING's 22011); a pad past 65535 bytes is 54000
#     at EXECUTE (it was a bare prepare refusal, and a computed length
#     answered).
#   * ROUND/TRUNC places outside -128..127 are the scale error; a large
#     negative places count is 0 (it overflowed); TRUNC of a DOUBLE uses
#     the engine's wrapping SINT64 power of ten (NaN past 63 places).
#   * BIN_SHL/BIN_SHR refuse a negative count; the BIN_* family refuses a
#     scaled / approximate / string operand at prepare with its typed
#     error, accepts a scale-0 NUMERIC / INT128 (refused before) and
#     shifts an INT128 in 128 bits; ATAN2(0, 0) raises.
#
# Round 2 (a refuter's findings, each measured first):
#
#   * the overflow of an INTEGER-read argument names the SOURCE's type:
#     an INT128 (a column, a CAST, a literal past BIGINT, a NUMERIC(38,s))
#     is the ARITHMETIC integer overflow, a DECFLOAT the decimal invalid
#     operation (DATEADD's toInt64: the FLOAT invalid operand), anything
#     narrower *numeric value is out of range* - round 1 said the last for
#     all, and SUBSTRING's start - 1 now keeps its operand's type;
#   * a constant length is read at prepare for a UTF8 source too (its
#     extra argument returned first), for a STRING literal, and for a
#     negative FOR past INTEGER (it named a wrapped 2147483647); a scaled
#     or string literal length describes its value (it was 65533);
#   * a text amount reads its exponent ('1e1' was 22018); ROUND past the
#     i128 is 22003 (it wrapped negative); POSITION's start over a UTF8
#     string counts characters (it counted bytes); TIMESTAMP +/- a number
#     keeps 0001..9999 (it answered year 10000); a DECFLOAT length / start
#     / amount / places count converts (it was refused); BIN_* over a
#     DECFLOAT, DATE or BOOLEAN is the typed refusal.
#   * RECORDED (section 15): an approximate LITERAL length (engine
#     VARYING(0) + 22001; refused here) and LPAD in PSQL / under HAVING /
#     in an IN (subquery); ROUND/TRUNC of a DECFLOAT operand answer now.
#
# Usage: qa/serve-real-fnargs.sh [port]   (default 5360)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5360}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/fnargs-eng.fdb"; FC="$D/fnargs-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, N INTEGER, BIG BIGINT, I128 INT128, NM NUMERIC(18,0), D DATE,
  TS TIMESTAMP, TM TIME, S VARCHAR(10), U VARCHAR(10) CHARACTER SET UTF8, DB DOUBLE PRECISION);
INSERT INTO T VALUES (1, -32768, 4294967297, 1, 5, '2024-02-29', '2024-01-01 00:00:00', '10:00:00', 'abc', 'abc', 0.5);
INSERT INTO T VALUES (2, 0, -1, -8, -3, '0001-01-01', '9999-12-31 23:59:00', '00:30:00', 'xyz', 'xyz', 0);
COMMIT;
CREATE TABLE T2 (I128X INT128, BI BIGINT, N380 NUMERIC(38,0), DF DECFLOAT, U2 VARCHAR(20) CHARACTER SET UTF8,
  N2 INTEGER, S VARCHAR(10), D DATE);
INSERT INTO T2 VALUES (170141183460469231731687303715884105727, 9223372036854775807,
  -170141183460469231731687303715884105728, 2.5, 'äbcdef', 2, 'abc', '2024-01-01');
SET TERM ^;
CREATE PROCEDURE PP (X VARCHAR(10) CHARACTER SET UTF8, L INTEGER) RETURNS (R VARCHAR(100) CHARACTER SET UTF8)
AS BEGIN R = LPAD(X, L, 'é'); SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/fnargs-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/fnargs-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/fnargs-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-fnargs-$PORT.log" 2>&1 & srv=$!
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
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# a RECORDED difference: the engine's answer is pinned, and this server
# must still give its known clean refusal - a cell that starts to agree
# FAILS, so it is promoted rather than left behind
rec() { # <label> <script> <engine-output> <this-server-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server answers [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: engine [$ev], this server [$fv])"; fi
}
DUAL='FROM RDB$DATABASE'
# ...and INT128's narrowing: the ARITHMETIC integer overflow
IOVF='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.'
E22003='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'

DATES='Statement failed, SQLSTATE = 22008|value exceeds the range for valid dates'
STAMPS='Statement failed, SQLSTATE = 22008|value exceeds the range for valid timestamps'
E54000='Statement failed, SQLSTATE = 54000|arithmetic exception, numeric overflow, or string truncation|-Implementation limit exceeded'
EVAL='Statement failed, SQLSTATE = 42000|expression evaluation not supported'
DD="DATE '2024-01-01'"
TS0="TIMESTAMP '2024-01-01 00:00:00'"
echo "--- 1. DATEADD: the quantity's bound, the result's range, the family named"
pin  "1 YEAR 4294967296 raises (it wrapped to 2024-01-01)" "SELECT DATEADD(YEAR, 4294967296, $DD) $DUAL;" \
     "DATEADD|$DATES"
pin  "1 YEAR at the BIGINT top (it answered 2023-01-01)" "SELECT DATEADD(YEAR, 9223372036854775807, $DD) $DUAL;" \
     "DATEADD|$DATES"
pin  "1 ...and the BIGINT bottom" "SELECT DATEADD(YEAR, -9223372036854775808, $DD) $DUAL;" \
     "DATEADD|$DATES"
pin  "1 DAY 2147483647 names valid dates" "SELECT DATEADD(DAY, 2147483647, $DD) $DUAL;" \
     "DATEADD|$DATES"
pin  "1 YEAR 10000 and a result past 9999" "SELECT DATEADD(YEAR, 10000, $DD) $DUAL;" \
     "DATEADD|$DATES"
pin  "1 one day before 0001-01-01" "SELECT DATEADD(DAY, -1, DATE '0001-01-01') $DUAL;" \
     "DATEADD|$DATES"
pin  "1 a TIMESTAMP past the end names valid timestamps" "SELECT DATEADD(MINUTE, 2, TIMESTAMP '9999-12-31 23:59:00') $DUAL;" \
     "DATEADD|$STAMPS"
pin  "1 ...a zoned one too" "SELECT DATEADD(YEAR, 1, CAST('9999-06-01 00:00:00 UTC' AS TIMESTAMP WITH TIME ZONE)) $DUAL;" \
     "DATEADD|$STAMPS"
pin  "1 MILLISECOND at the BIGINT top is 22003 (scale -1 overflows)" "SELECT DATEADD(MILLISECOND, 9223372036854775807, $TS0) $DUAL;" \
     "DATEADD|$E22003"
pin  "1 DAY 1e300 is 22003" "SELECT DATEADD(DAY, 1e300, $DD) $DUAL;" \
     "DATEADD|$E22003"
pin  "1 a TIME past the middle day's reach names a valid time" "SELECT DATEADD(HOUR, 43825000, TIME '00:00:00') $DUAL;" \
     "DATEADD|Statement failed, SQLSTATE = 22008|value exceeds the range for a valid time"
pin  "1 CONTROL ...and just inside it wraps" "SELECT DATEADD(HOUR, 43824000, TIME '00:00:00'), DATEADD(HOUR, -1, TIME '00:30:00') $DUAL;" \
     "DATEADD DATEADD|00:00:00.0000 23:30:00.0000"
pin  "1 CONTROL the last year that fits" "SELECT DATEADD(YEAR, 7975, $DD) $DUAL;" \
     "DATEADD|9999-01-01"
pin  "1 a DATE + 1 past 9999-12-31 names valid dates" "SELECT DATE '9999-12-31' + 1 $DUAL;" \
     "ADD|$DATES"
pin  "1 a column amount past the INTEGER range" "SELECT DATEADD(YEAR, BIG, D) FROM T WHERE ID = 1;" \
     "DATEADD|$DATES"
echo "--- 2. DATEADD: the fractional millisecond, the DATE's truncation, Feb 29"
pin  "2 MILLISECOND 0.5 / 1.26 / 1.25 / -0.5 keep 100us" "SELECT DATEADD(MILLISECOND, 0.5, $TS0), DATEADD(MILLISECOND, 1.26, $TS0), DATEADD(MILLISECOND, 1.25, $TS0), DATEADD(MILLISECOND, -0.5, $TS0) $DUAL;" \
     "DATEADD DATEADD DATEADD DATEADD|2024-01-01 00:00:00.0005 2024-01-01 00:00:00.0013 2024-01-01 00:00:00.0013 2023-12-31 23:59:59.9995"
pin  "2 ...over a TIME" "SELECT DATEADD(MILLISECOND, 0.5, TIME '10:00:00'), DATEADD(MILLISECOND, 0.05, TIME '10:00:00'), DATEADD(MILLISECOND, 0.04, TIME '10:00:00') $DUAL;" \
     "DATEADD DATEADD DATEADD|10:00:00.0005 10:00:00.0001 10:00:00.0000"
pin  "2 ...a DOUBLE and a string amount (refused before)" "SELECT DATEADD(MILLISECOND, 0.5e0, $TS0), DATEADD(MILLISECOND, CAST(0.25 AS DOUBLE PRECISION), $TS0), DATEADD(MILLISECOND, '1.5', $TS0), DATEADD(DAY, '3', $DD) $DUAL;" \
     "DATEADD DATEADD DATEADD DATEADD|2024-01-01 00:00:00.0005 2024-01-01 00:00:00.0003 2024-01-01 00:00:00.0015 2024-01-04"
pin  "2 ...a DOUBLE column" "SELECT DATEADD(MILLISECOND, DB, TS) FROM T WHERE ID = 1;" \
     "DATEADD|2024-01-01 00:00:00.0005"
pin  "2 a DATE takes clock units truncated toward zero" "SELECT DATEADD(HOUR, -25, $DD), DATEADD(MINUTE, -1, $DD), DATEADD(SECOND, -86401, $DD), DATEADD(MILLISECOND, 86399999.9, $DD) $DUAL;" \
     "DATEADD DATEADD DATEADD DATEADD|2023-12-31 2024-01-01 2023-12-31 2024-01-01"
pin  "2 Feb 29 forward into a non-leap year lands on the last day" "SELECT DATEADD(MONTH, 13, D), DATEADD(MONTH, 14, D), DATEADD(MONTH, 25, D) FROM T WHERE ID = 1;" \
     "DATEADD DATEADD DATEADD|2025-03-31 2025-04-30 2026-03-31"
pin  "2 CONTROL ...within a leap year, backwards, by YEAR" "SELECT DATEADD(MONTH, 1, D), DATEADD(MONTH, -11, D), DATEADD(MONTH, 12, D), DATEADD(YEAR, 1, D) FROM T WHERE ID = 1;" \
     "DATEADD DATEADD DATEADD DATEADD|2024-03-29 2023-03-29 2025-02-28 2025-02-28"
pin  "2 CONTROL whole seconds, rounded amounts" "SELECT DATEADD(SECOND, 0.5, $TS0), DATEADD(DAY, 2.5, $DD), DATEADD(DAY, -2.5, $DD) $DUAL;" \
     "DATEADD DATEADD DATEADD|2024-01-01 00:00:01.0000 2024-01-04 2023-12-29"
echo "--- 3. SUBSTRING / LEFT / RIGHT / POSITION: INTEGER arguments"
pin  "3 a constant FOR past INTEGER fails the PREPARE (it described len -2147483648)" "SELECT SUBSTRING('abc' FROM 1 FOR 2147483648) $DUAL;" \
     "$E22003"
pin  "3 ...even under WHERE 1=0" "SELECT SUBSTRING('abc' FROM 1 FOR 4294967298) $DUAL WHERE 1 = 0;" \
     "$E22003"
pin  "3 ...a computed one at execute" "SELECT SUBSTRING('abc' FROM 1 FOR 2147483648 + 0) $DUAL;" \
     "SUBSTRING|$E22003"
pin  "3 FROM past INTEGER" "SELECT SUBSTRING('abc' FROM 4294967298) $DUAL;" \
     "SUBSTRING|$E22003"
pin  "3 FROM whose predecessor leaves INTEGER" "SELECT SUBSTRING('abc' FROM -2147483648 FOR 2147483647) $DUAL;" \
     "SUBSTRING|$E22003"
pin  "3 CONTROL FROM 2147483648 is still in range, empty" "SELECT '[' || SUBSTRING('abc' FROM 2147483648) || ']' $DUAL;" \
     "CONCATENATION|[]"
pin  "3 FROM 0.5 rounds AFTER the subtraction" "SELECT SUBSTRING('abc' FROM 0.5 FOR 2), SUBSTRING('abc' FROM 1.5 FOR 1) $DUAL;" \
     "SUBSTRING SUBSTRING|a b"
dsame "3 CONTROL the describe of a constant FOR" "SELECT SUBSTRING('abc' FROM 1 FOR 70000), SUBSTRING('abc' FROM 1 FOR 2) $DUAL;"
pin  "3 LEFT past INTEGER (it answered abc)" "SELECT LEFT('abc', 4294967298) $DUAL;" \
     "LEFT|$E22003"
pin  "3 LEFT below INTEGER is 22003, not a wrapped 22011" "SELECT LEFT('abc', -2147483649) $DUAL;" \
     "LEFT|$E22003"
pin  "3 LEFT 2147483647.5 rounds out of range" "SELECT LEFT('abc', 2147483647.5) $DUAL;" \
     "LEFT|$E22003"
pin  "3 LEFT of a DOUBLE count (it refused)" "SELECT LEFT('abc', 1.5e0) $DUAL;" \
     "LEFT|ab"
pin  "3 RIGHT at the BIGINT top" "SELECT RIGHT('abc', 9223372036854775807) $DUAL;" \
     "RIGHT|$E22003"
pin  "3 a column count past INTEGER" "SELECT LEFT(S, BIG) FROM T WHERE ID = 1;" \
     "LEFT|$E22003"
pin  "3 CONTROL LEFT/RIGHT negative stay SUBSTRING's 22011" "SELECT LEFT('abc', -1) $DUAL;" \
     "LEFT|Statement failed, SQLSTATE = 22011|Invalid length parameter -1 to SUBSTRING. Negative integers are not allowed."
pin  "3 POSITION start past INTEGER (it answered 0)" "SELECT POSITION('a', 'abc', 4294967297) $DUAL;" \
     "POSITION|$E22003"
pin  "3 POSITION start 0 is its own #3 error (it was 22011)" "SELECT POSITION('a', 'abc', 0) $DUAL;" \
     "POSITION|$EVAL|-Argument #3 for POSITION must be positive"
pin  "3 ...and -1" "SELECT POSITION('a', 'abc', -1) $DUAL;" \
     "POSITION|$EVAL|-Argument #3 for POSITION must be positive"
pin  "3 ...far below INTEGER is 22003 first" "SELECT POSITION('a', 'abc', -4294967297) $DUAL;" \
     "POSITION|$E22003"
pin  "3 CONTROL POSITION in range" "SELECT POSITION('b', 'abc', 1.5), POSITION('b', 'abc', 2.5), POSITION('a', 'abc', 2147483647) $DUAL;" \
     "POSITION POSITION POSITION|2 0 0"
echo "--- 4. LPAD / RPAD"
pin  "4 a negative length is LPAD's #2 error (it was 22011)" "SELECT LPAD('abc', -1) $DUAL;" \
     "LPAD|$EVAL|-Argument #2 for LPAD must be zero or positive"
pin  "4 ...RPAD's, with a pad" "SELECT RPAD('abc', -1, 'x') $DUAL;" \
     "RPAD|$EVAL|-Argument #2 for RPAD must be zero or positive"
pin  "4 ...a computed one" "SELECT LPAD('abc', N) FROM T WHERE ID = 1;" \
     "LPAD|$EVAL|-Argument #2 for LPAD must be zero or positive"
pin  "4 a constant past INTEGER fails the PREPARE" "SELECT LPAD('abc', 2147483648) $DUAL WHERE 1 = 0;" \
     "$E22003"
pin  "4 ...RPAD at the BIGINT top" "SELECT RPAD('a', 9223372036854775807) $DUAL;" \
     "$E22003"
pin  "4 ...a computed one at execute" "SELECT LPAD('abc', 4294967298 + 0) $DUAL;" \
     "LPAD|$E22003"
pin  "4 past 65535 bytes is 54000 (a bare prepare refusal before)" "SELECT CHAR_LENGTH(LPAD('abc', 65536)) $DUAL;" \
     "CHAR_LENGTH|$E54000"
pin  "4 ...a computed length too (it answered 65536)" "SELECT CHAR_LENGTH(LPAD('abc', 65536 + 0)) $DUAL;" \
     "CHAR_LENGTH|$E54000"
pin  "4 ...INTEGER's top" "SELECT LPAD('a', 2147483647) $DUAL;" \
     "LPAD|$E54000"
pin  "4 ...a UTF8 source at 16384 characters" "SELECT CHAR_LENGTH(RPAD(U, 16384 + 0)) FROM T WHERE ID = 1;" \
     "CHAR_LENGTH|$E54000"
pin  "4 CONTROL the largest pads" "SELECT CHAR_LENGTH(LPAD('abc', 65535)), CHAR_LENGTH(LPAD('abc', 65535 + 0)), CHAR_LENGTH(LPAD(U, 16383)) FROM T WHERE ID = 1;" \
     "CHAR_LENGTH CHAR_LENGTH CHAR_LENGTH|65535 65535 16383"
dsame "4 a constant past the limit prepares, VARYING(65533)" "SELECT LPAD('abc', 100000) $DUAL WHERE 1 = 0;"
pin  "4 CONTROL an ordinary pad" "SELECT LPAD('abc', 5, 'xy'), RPAD('abc', 2.5) $DUAL;" \
     "LPAD RPAD|xyabc abc"
echo "--- 5. ROUND / TRUNC places"
pin  "5 ROUND places 200 is the scale error (it answered 1.5)" "SELECT ROUND(1.5, 200) $DUAL;" \
     "ROUND|$EVAL|-The numeric scale must be between -128 and 127 in ROUND"
pin  "5 ...-129, and 127.5 rounded to 128" "SELECT ROUND(1.5, -129) $DUAL;" \
     "ROUND|$EVAL|-The numeric scale must be between -128 and 127 in ROUND"
pin  "5 ...127.5" "SELECT ROUND(1.5, 127.5) $DUAL;" \
     "ROUND|$EVAL|-The numeric scale must be between -128 and 127 in ROUND"
pin  "5 ...INTEGER's bottom" "SELECT ROUND(1.5, -2147483648) $DUAL;" \
     "ROUND|$EVAL|-The numeric scale must be between -128 and 127 in ROUND"
pin  "5 ...past INTEGER is 22003 first" "SELECT ROUND(1.5, 4294967296) $DUAL;" \
     "ROUND|$E22003"
pin  "5 ...a DOUBLE operand's scale error (it was 22003)" "SELECT ROUND(1.5e0, 400) $DUAL;" \
     "ROUND|$EVAL|-The numeric scale must be between -128 and 127 in ROUND"
pin  "5 TRUNC's scale error names TRUNC" "SELECT TRUNC(123, 128) $DUAL;" \
     "TRUNC|$EVAL|-The numeric scale must be between -128 and 127 in TRUNC"
pin  "5 a large negative places count is 0 (it overflowed)" "SELECT ROUND(1.5, -128), ROUND(123, -100), TRUNC(123, -100), TRUNC(123, -128) $DUAL;" \
     "ROUND ROUND TRUNC TRUNC|0.0 0 0 0"
pin  "5 ...over an INT128" "SELECT ROUND(CAST(123 AS INT128), -100), TRUNC(CAST(123 AS INT128), -100), ROUND(CAST(123 AS INT128), -39) $DUAL;" \
     "ROUND TRUNC ROUND|0 0 0"
pin  "5 ...a DOUBLE ROUND to -128 places" "SELECT ROUND(1.5e0, -128) $DUAL;" \
     "ROUND|0.000000000000000"
pin  "5 TRUNC of a DOUBLE past 63 places is NaN (the wrapped power)" "SELECT TRUNC(1.5e0, 127), TRUNC(123e0, -100), TRUNC(123e0, -128) $DUAL;" \
     "TRUNC TRUNC TRUNC|NaN NaN NaN"
pin  "5 ...19 and 20 places divide by the wrapped value" "SELECT TRUNC(1.5e0, 19), TRUNC(1.5e0, 20), TRUNC(123e0, -19), TRUNC(123e0, -20) $DUAL;" \
     "TRUNC TRUNC TRUNC TRUNC|1.500000000000000 1.500000000000000 0.000000000000000 0.000000000000000"
pin  "5 CONTROL in-range places" "SELECT ROUND(1.5, 127), ROUND(1.5, 127.4), TRUNC(123, -10), TRUNC(1.5, 127), ROUND(123, -19) $DUAL;" \
     "ROUND ROUND TRUNC TRUNC ROUND|1.5 1.5 0 1.5 0"
pin  "5 CONTROL a DOUBLE rounded past INT64 is 22003" "SELECT ROUND(1.5e0, 127) $DUAL;" \
     "ROUND|$E22003"
echo "--- 6. BIN_* and ATAN2"
pin  "6 BIN_SHL by a negative count (it answered -9223372036854775808)" "SELECT BIN_SHL(1, -1) $DUAL;" \
     "BIN_SHL|$EVAL|-Argument for BIN_SHL must be zero or positive"
pin  "6 BIN_SHR by a negative count" "SELECT BIN_SHR(8, -1) $DUAL;" \
     "BIN_SHR|$EVAL|-Argument for BIN_SHR must be zero or positive"
pin  "6 ...a column count" "SELECT BIN_SHL(BIG, N) FROM T WHERE ID = 1;" \
     "BIN_SHL|$EVAL|-Argument for BIN_SHL must be zero or positive"
pin  "6 ...an INT128 operand" "SELECT BIN_SHL(CAST(1 AS INT128), -1) $DUAL;" \
     "BIN_SHL|$EVAL|-Argument for BIN_SHL must be zero or positive"
pin  "6 a scaled count is the typed prepare refusal" "SELECT BIN_SHL(1, 2.7) $DUAL WHERE 1 = 0;" \
     "$EVAL|-Arguments for BIN_SHL must be integral types or NUMERIC/DECIMAL without scale"
pin  "6 ...BIN_AND of a decimal" "SELECT BIN_AND(1.5, 1) $DUAL;" \
     "$EVAL|-Arguments for BIN_AND must be integral types or NUMERIC/DECIMAL without scale"
pin  "6 ...BIN_OR of a DOUBLE" "SELECT BIN_OR(1, 2e0) $DUAL;" \
     "$EVAL|-Arguments for BIN_OR must be integral types or NUMERIC/DECIMAL without scale"
pin  "6 ...BIN_XOR of a string" "SELECT BIN_XOR(1, '2') $DUAL;" \
     "$EVAL|-Arguments for BIN_XOR must be integral types or NUMERIC/DECIMAL without scale"
pin  "6 ...BIN_NOT of NUMERIC(2,1)" "SELECT BIN_NOT(1.0) $DUAL;" \
     "$EVAL|-Arguments for BIN_NOT must be integral types or NUMERIC/DECIMAL without scale"
pin  "6 ...a DOUBLE column" "SELECT BIN_SHR(ID, DB) FROM T;" \
     "$EVAL|-Arguments for BIN_SHR must be integral types or NUMERIC/DECIMAL without scale"
pin  "6 a scale-0 NUMERIC is integral (it refused)" "SELECT BIN_SHL(CAST(5 AS NUMERIC(18,0)), 1), BIN_AND(NM, 3) FROM T WHERE ID = 1;" \
     "BIN_SHL BIN_AND|10 1"
pin  "6 an INT128 shifts in 128 bits" "SELECT BIN_SHL(CAST(1 AS INT128), 64), BIN_SHL(CAST(3 AS INT128), 127), BIN_SHL(I128, 100) FROM T WHERE ID = 1;" \
     "BIN_SHL BIN_SHL BIN_SHL|18446744073709551616 -170141183460469231731687303715884105728 1267650600228229401496703205376"
pin  "6 ...and past 127 (or a negative int count) every bit is out" "SELECT BIN_SHL(CAST(1 AS INT128), 128), BIN_SHR(I128, 128), BIN_SHR(CAST(8 AS INT128), 130), BIN_SHL(CAST(1 AS INT128), 4294967295) FROM T WHERE ID = 2;" \
     "BIN_SHL BIN_SHR BIN_SHR BIN_SHL|0 -1 0 0"
pin  "6 CONTROL an INT64 count wraps at 64" "SELECT BIN_SHL(1, 64), BIN_SHL(1, 65), BIN_SHL(1, 4294967297), BIN_SHR(-8, 100), BIN_SHL(1, 9223372036854775807) $DUAL;" \
     "BIN_SHL BIN_SHL BIN_SHL BIN_SHR BIN_SHL|1 2 2 -1 -9223372036854775808"
pin  "6 ATAN2(0, 0) raises (it answered 0)" "SELECT ATAN2(0, 0) $DUAL;" \
     "ATAN2|$EVAL|-Arguments for ATAN2 cannot both be zero"
pin  "6 ...either zero signed, a column" "SELECT ATAN2(-0e0, N) FROM T WHERE ID = 2;" \
     "ATAN2|$EVAL|-Arguments for ATAN2 cannot both be zero"
pin  "6 CONTROL ATAN2 off the origin" "SELECT ATAN2(0, 1), ATAN2(1, 0) $DUAL;" \
     "ATAN2 ATAN2|0.000000000000000 1.570796326794897"
echo "--- 8. the overflow names the SOURCE's type (round 2)"
# MOV_get_long / MOV_get_int64 of an INT128 is Int128's own narrowing -
# the ARITHMETIC integer overflow - of a DECFLOAT the decimal (or, through
# toInt64, the float) invalid operation, and of anything narrower CVT's
# *numeric value is out of range*; round 1 named the last for all of them
pin  "8 an INT128 column as a DATEADD amount" "SELECT DATEADD(DAY, I128X, D) FROM T2;" \
     "DATEADD|$IOVF"
pin  "8 ...as a LEFT length" "SELECT LEFT(S, I128X) FROM T2;" \
     "LEFT|$IOVF"
pin  "8 ...as a POSITION start" "SELECT POSITION('a', S, I128X) FROM T2;" \
     "POSITION|$IOVF"
pin  "8 ...as an LPAD length" "SELECT LPAD(S, I128X) FROM T2;" \
     "LPAD|$IOVF"
pin  "8 ...as ROUND places" "SELECT ROUND(1.25, I128X) FROM T2;" \
     "ROUND|$IOVF"
pin  "8 ...as a BIN_SHL count" "SELECT BIN_SHL(1, I128X) FROM T2;" \
     "BIN_SHL|$IOVF"
pin  "8 ...as a SUBSTRING FOR" "SELECT SUBSTRING(S FROM 1 FOR I128X) FROM T2;" \
     "SUBSTRING|$IOVF"
pin  "8 an INT128 cast past INTEGER (master answered 'abc')" "SELECT LEFT('abc', CAST(4294967296 AS INT128)) $DUAL;" \
     "LEFT|$IOVF"
pin  "8 ...as ROUND places (master answered 1.5)" "SELECT ROUND(1.5, CAST(4294967296 AS INT128)) $DUAL;" \
     "ROUND|$IOVF"
pin  "8 an integer literal past BIGINT is INT128" "SELECT DATEADD(DAY, 9223372036854775808, $DD) $DUAL;" \
     "DATEADD|$IOVF"
pin  "8 ...as a LEFT length" "SELECT LEFT(S, 9223372036854775808) FROM T2;" \
     "LEFT|$IOVF"
pin  "8 a NUMERIC(38,2) is INT128-backed" "SELECT LEFT(S, CAST(4294967296 AS NUMERIC(38,2))) FROM T2;" \
     "LEFT|$IOVF"
pin  "8 MILLISECOND's scale -1 over an INT128" "SELECT DATEADD(MILLISECOND, CAST(922337203685477581 AS INT128), $TS0) $DUAL;" \
     "DATEADD|$IOVF"
pin  "8 a constant INT128 pad length fails the prepare" "SELECT LPAD('abc', 9223372036854775808) $DUAL WHERE 1 = 0;" \
     "$IOVF"
pin  "8 SUBSTRING's start - 1 overflows a BIGINT FROM itself" "SELECT SUBSTRING(S FROM -BI-1) FROM T2;" \
     "SUBSTRING|Statement failed, SQLSTATE = 22003|Integer overflow. The result of an integer operation caused the most significant bit of the result to carry."
pin  "8 ...an INT128 FROM stays INT128" "SELECT SUBSTRING(S FROM CAST(2147483649 AS INT128)) FROM T2;" \
     "SUBSTRING|$IOVF"
pin  "8 CONTROL ...and one that fits is empty" "SELECT '[' || SUBSTRING(S FROM CAST(2147483648 AS INT128)) || ']' FROM T2;" \
     "CONCATENATION|[]"
pin  "8 CONTROL a BIGINT literal / column is out of range" "SELECT LEFT(S, 4294967296) FROM T2;" \
     "LEFT|$E22003"
pin  "8 CONTROL ...a BIGINT column" "SELECT LEFT(S, BI) FROM T2;" \
     "LEFT|$E22003"
pin  "8 CONTROL ...a BIGINT FROM" "SELECT SUBSTRING(S FROM 2147483649) FROM T2;" \
     "SUBSTRING|$E22003"
echo "--- 9. constant lengths (round 2)"
pin  "9 a UTF8 source's constant pad length fails the prepare too" "SELECT LPAD(U, 2147483648) FROM T WHERE 1 = 0;" \
     "$E22003"
pin  "9 ...RPAD, with rows" "SELECT RPAD(U, 3000000000) FROM T;" \
     "$E22003"
pin  "9 a negative FOR past INTEGER is 22003 (it named 2147483647)" "SELECT SUBSTRING('abcdef' FROM 1 FOR -2147483649) $DUAL WHERE 1 = 0;" \
     "$E22003"
pin  "9 ...over a column" "SELECT SUBSTRING(S FROM 1 FOR -2147483649) FROM T;" \
     "$E22003"
pin  "9 CONTROL FOR -2147483648 is the length error" "SELECT SUBSTRING(S FROM 1 FOR -2147483648) FROM T;" \
     "Statement failed, SQLSTATE = 22011|Invalid length parameter -2147483648 to SUBSTRING. Negative integers are not allowed."
pin  "9 a STRING constant pad length is read at prepare" "SELECT LPAD('abc', '2147483648') $DUAL WHERE 1 = 0;" \
     "$E22003"
pin  "9 ...a string FOR" "SELECT SUBSTRING('abc' FROM 1 FOR '2147483648') $DUAL WHERE 1 = 0;" \
     "$E22003"
pin  "9 ...a non-numeric one is 22018 at prepare" "SELECT LPAD('abc', 'x') $DUAL WHERE 1 = 0;" \
     "Statement failed, SQLSTATE = 22018|conversion error from string \"x\""
dsame "9 LPAD('ab', 5.0) describes 5 (it announced 65533)" "SELECT LPAD('ab', 5.0) $DUAL;"
dsame "9 LPAD('ab', 4.6) rounds to 5" "SELECT LPAD('ab', 4.6) $DUAL;"
dsame "9 LPAD('abc', '5') describes 5" "SELECT LPAD('abc', '5') $DUAL;"
pin  "9 ...and they answer" "SELECT LPAD('ab', 5.0), LPAD('ab', 4.6), LPAD('abc', '5') $DUAL;" \
     "LPAD LPAD LPAD|ab ab abc"
pin  "9 CONTROL a computed DOUBLE length answers" "SELECT LPAD('ab', CAST(5 AS DOUBLE PRECISION)), LEFT('abcdef', 2e0) $DUAL;" \
     "LPAD LEFT|ab ab"
echo "--- 10. a text amount is CVT's, exponent included (round 2)"
pin  "10 DATEADD(DAY, '1e1') (it was 22018)" "SELECT DATEADD(DAY, '1e1', DATE '2024-02-29') $DUAL;" \
     "DATEADD|2024-03-10"
pin  "10 LEFT '1e0', '1.5e0', ' 2 '" "SELECT LEFT('abc', '1e0'), LEFT('abc', '1.5e0'), LEFT('abc', ' 2 '), '[' || LEFT('abc', '1e-400') || ']' $DUAL;" \
     "LEFT LEFT LEFT CONCATENATION|a ab ab []"
pin  "10 ...'-1e0' is the length error" "SELECT LEFT('abc', '-1e0') $DUAL;" \
     "LEFT|Statement failed, SQLSTATE = 22011|Invalid length parameter -1 to SUBSTRING. Negative integers are not allowed."
pin  "10 ...'1e10' is 22003" "SELECT LEFT('abc', '1e10') $DUAL;" \
     "LEFT|$E22003"
pin  "10 ...'1e400' is 22003" "SELECT LEFT('abc', '1e400') $DUAL;" \
     "LEFT|$E22003"
pin  "10 ...a digit string past INT64 is 22003" "SELECT LEFT('abc', '99999999999999999999999') $DUAL;" \
     "LEFT|$E22003"
pin  "10 MILLISECOND '1.5e0'" "SELECT DATEADD(MILLISECOND, '1.5e0', $TS0) $DUAL;" \
     "DATEADD|2024-01-01 00:00:00.0015"
pin  "10 CONTROL '2e' is 22018" "SELECT LEFT('abc', '2e') $DUAL;" \
     "LEFT|Statement failed, SQLSTATE = 22018|conversion error from string \"2e\""
echo "--- 11. ROUND past the i128 (round 2)"
pin  "11 ROUND(INT128 max, -1) is 22003 (it wrapped negative)" "SELECT ROUND(I128X, -1) FROM T2;" \
     "ROUND|$E22003"
pin  "11 ...-38" "SELECT ROUND(I128X, -38) FROM T2;" \
     "ROUND|$E22003"
pin  "11 NUMERIC(38,0) min, -38" "SELECT ROUND(N380, -38) FROM T2;" \
     "ROUND|$E22003"
pin  "11 ...-1" "SELECT ROUND(N380, -1) FROM T2;" \
     "ROUND|$E22003"
pin  "11 CONTROL TRUNC cannot overflow; -37 and -39 fit" "SELECT TRUNC(I128X, -1), ROUND(I128X, -37), ROUND(I128X, -39) FROM T2;" \
     "TRUNC ROUND ROUND|170141183460469231731687303715884105720 170000000000000000000000000000000000000 0"
pin  "11 CONTROL a BIGINT round-up is 22003" "SELECT ROUND(BI, -1) FROM T2;" \
     "ROUND|$E22003"
echo "--- 12. POSITION's start over a UTF8 string (round 2)"
pin  "12 POSITION('c', U2, 2) counts characters (it said 4)" "SELECT POSITION('c', U2, 2), POSITION('c', U2, N2), POSITION('c', U2, 4) FROM T2;" \
     "POSITION POSITION POSITION|3 3 0"
pin  "12 ...'ä' from 1, 'b' from 2 and 3" "SELECT POSITION('ä', U2, 1), POSITION('b', U2, 2), POSITION('b', U2, 3) FROM T2;" \
     "POSITION POSITION POSITION|1 2 0"
pin  "12 ...an empty needle up to one past the end" "SELECT POSITION('', U2, 3), POSITION('', U2, 7), POSITION('', U2, 8) FROM T2;" \
     "POSITION POSITION POSITION|3 7 0"
pin  "12 CONTROL the two-argument form" "SELECT POSITION('c' IN U2), POSITION('ä', U2) FROM T2;" \
     "POSITION POSITION|3 1"
echo "--- 13. TIMESTAMP +/- a number keeps the calendar's range (round 2)"
pin  "13 + 1 past 9999-12-31 (it answered year 10000)" "SELECT TIMESTAMP '9999-12-31 23:00:00' + 1 $DUAL;" \
     "ADD|$STAMPS"
pin  "13 ...+ 0.05" "SELECT TIMESTAMP '9999-12-31 23:00:00' + 0.05 $DUAL;" \
     "ADD|$STAMPS"
pin  "13 ...- 1 before 0001-01-01" "SELECT TIMESTAMP '0001-01-01 01:00:00' - 1 $DUAL;" \
     "SUBTRACT|$STAMPS"
pin  "13 ...1 + TIMESTAMP" "SELECT 1 + TIMESTAMP '9999-12-31 23:00:00' $DUAL;" \
     "ADD|$STAMPS"
pin  "13 ...- (-1)" "SELECT TIMESTAMP '9999-12-31 23:00:00' - (-1) $DUAL;" \
     "SUBTRACT|$STAMPS"
pin  "13 more days than the calendar spans is valid DATES" "SELECT TIMESTAMP '2024-01-01 00:00:00' + 3652059 $DUAL;" \
     "ADD|$DATES"
pin  "13 ...a literal past INT64" "SELECT TIMESTAMP '2024-01-01 00:00:00' + 99999999999999999999999 $DUAL;" \
     "ADD|$DATES"
pin  "13 ...the span itself (and a half) is valid timestamps" "SELECT TIMESTAMP '2024-01-01 00:00:00' + 3652058.5 $DUAL;" \
     "ADD|$STAMPS"
pin  "13 ...- the span" "SELECT TIMESTAMP '2024-01-01 00:00:00' - 3652058 $DUAL;" \
     "SUBTRACT|$STAMPS"
pin  "13 CONTROL in-range fractions" "SELECT TIMESTAMP '9999-12-31 23:00:00' + 0.01, TIMESTAMP '9999-12-31 00:00:00' + 0.99999, $TS0 + 1.5 $DUAL;" \
     "ADD ADD ADD|9999-12-31 23:14:24.0000 9999-12-31 23:59:59.1360 2024-01-02 12:00:00.0000"
echo "--- 14. a DECFLOAT integer argument (round 2; all refused before)"
pin  "14 LEFT(S, DF 2.5) rounds half up" "SELECT LEFT(S, DF), RIGHT(S, DF), RPAD(S, DF, '*') FROM T2;" \
     "LEFT RIGHT RPAD|abc abc abc"
pin  "14 DATEADD(DAY, DF)" "SELECT DATEADD(DAY, DF, D), DATEADD(MILLISECOND, DF, $TS0), DATEADD(MILLISECOND, CAST('0.25' AS DECFLOAT), $TS0) FROM T2;" \
     "DATEADD DATEADD DATEADD|2024-01-04 2024-01-01 00:00:00.0025 2024-01-01 00:00:00.0003"
pin  "14 SUBSTRING FROM / FOR" "SELECT SUBSTRING(S FROM CAST('0.5' AS DECFLOAT) FOR 2), SUBSTRING(S FROM CAST('1.5' AS DECFLOAT) FOR DF), POSITION('b', S, DF) FROM T2;" \
     "SUBSTRING SUBSTRING POSITION|a bc 0"
pin  "14 ROUND/TRUNC places" "SELECT ROUND(1.25, DF), TRUNC(1.25, DF) FROM T2;" \
     "ROUND TRUNC|1.25 1.25"
pin  "14 ...places 200 is the scale error" "SELECT ROUND(1.25, CAST('200' AS DECFLOAT)) FROM T2;" \
     "ROUND|$EVAL|-The numeric scale must be between -128 and 127 in ROUND"
pin  "14 -2.5 is -3, the length error" "SELECT LEFT(S, CAST(-2.5 AS DECFLOAT)) FROM T2;" \
     "LEFT|Statement failed, SQLSTATE = 22011|Invalid length parameter -3 to SUBSTRING. Negative integers are not allowed."
pin  "14 past INTEGER is the decimal invalid operation" "SELECT LEFT(S, CAST('1e10' AS DECFLOAT)) FROM T2;" \
     "LEFT|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation."
pin  "14 ...a NaN" "SELECT LEFT(S, CAST('NaN' AS DECFLOAT)) FROM T2;" \
     "LEFT|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation."
pin  "14 past INT64 through toInt64 is the FLOAT invalid operand" "SELECT DATEADD(DAY, CAST('1e20' AS DECFLOAT), D) FROM T2;" \
     "DATEADD|Statement failed, SQLSTATE = 22000|Floating-point invalid operand. An indeterminant error occurred during a floating-point operation."
pin  "14 ...but a NaN is the decimal one" "SELECT DATEADD(DAY, CAST('NaN' AS DECFLOAT), D) FROM T2;" \
     "DATEADD|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation."
pin  "14 ...in INT64, the day bound" "SELECT DATEADD(DAY, CAST('1e10' AS DECFLOAT), D) FROM T2;" \
     "DATEADD|$DATES"
pin  "14 BIN_SHL of a DECFLOAT count is the typed refusal" "SELECT BIN_SHL(1, DF) FROM T2;" \
     "$EVAL|-Arguments for BIN_SHL must be integral types or NUMERIC/DECIMAL without scale"
pin  "14 BIN_AND of a DECFLOAT (it was a bare Dynamic SQL Error)" "SELECT BIN_AND(CAST(1 AS DECFLOAT), 1) $DUAL;" \
     "$EVAL|-Arguments for BIN_AND must be integral types or NUMERIC/DECIMAL without scale"
pin  "14 ...of a DATE" "SELECT BIN_AND(DATE '2024-01-01', 1) $DUAL;" \
     "$EVAL|-Arguments for BIN_AND must be integral types or NUMERIC/DECIMAL without scale"
pin  "14 ...of a BOOLEAN" "SELECT BIN_AND(TRUE, 1) $DUAL;" \
     "$EVAL|-Arguments for BIN_AND must be integral types or NUMERIC/DECIMAL without scale"
echo "--- 15. RECORDED in round 2, not fixed"
# an APPROXIMATE LITERAL length is read by the describe as 0: the engine
# announces VARYING(0) and fails the move of a non-empty result (22001),
# while an expression over it still sees the whole string (CHAR_LENGTH is
# 5). This server has no zero-width text slot; it refuses the prepare, as
# master did, rather than answer the padded string as round 1 did
rec  "15 LPAD('ab', 5e0)" "SELECT LPAD('ab', 5e0) $DUAL;" \
     "LPAD|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 0, actual 5" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
rec  "15 SUBSTRING FOR 2e0" "SELECT SUBSTRING('abcdef' FROM 1 FOR 2e0) $DUAL;" \
     "SUBSTRING|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 0, actual 2" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
rec  "15 CHAR_LENGTH(LPAD('ab', 5e0))" "SELECT CHAR_LENGTH(LPAD('ab', 5e0)) $DUAL;" \
     "CHAR_LENGTH|5" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
# ROUND/TRUNC of a DECFLOAT OPERAND answers a DECFLOAT on the engine (with
# its own cohort rules - ROUND(DF, -128) is 0E-128, TRUNC's power of ten
# wraps); implemented in the widenum review round (serve-real-widenum.sh
# section 9 pins the laws) - promoted from recorded
pin  "15 ROUND/TRUNC of a DECFLOAT" "SELECT ROUND(DF, 1), TRUNC(DF, 1) FROM T2;" \
     "ROUND TRUNC|2.5 2.5"
pin  "15 TRUNC(DF, 128)" "SELECT TRUNC(DF, 128) FROM T2;" \
     "TRUNC|$EVAL|-The numeric scale must be between -128 and 127 in TRUNC"
# LPAD/LEFT/REPLACE inside PSQL, and a function under HAVING or in an
# IN (subquery), are refused by this server whatever the arguments - a
# wider gap than the argument checks (the same on master)
rec  "15 LPAD in a procedure" "SELECT * FROM PP('ab', 5);" \
     "R|éééab" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
rec  "15 RPAD under GROUP BY ... HAVING" "SELECT RPAD(S, 5, '*') AS X FROM T GROUP BY 1 HAVING RPAD(S, 5, '*') > '';" \
     "X|abc**|xyz**" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
rec  "15 LPAD in an IN (subquery)" "SELECT 1 FROM T WHERE '**abc' IN (SELECT LPAD(S, 5, '*') FROM T);" \
     "CONSTANT|1|1" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
echo "--- 7. RECORDED, not fixed"
# the describe of a NEGATIVE constant pad length: the engine's makePad
# computes 2 + fixLength(-1 * bpc) into a USHORT and announces VARYING(1);
# this server announces the widest VARYING. The statement raises LPAD's #2
# error at execute on both, so no row ever carries the difference.
ran=$((ran + 1))
ed=$(dsc "127.0.0.1/$REAL:$ENG" "SELECT LPAD('abc', -1) $DUAL WHERE 1 = 0;"); fd=$(dsc "127.0.0.1/$PORT:$FC" "SELECT LPAD('abc', -1) $DUAL WHERE 1 = 0;")
if [ -n "$ed" ] && [ -n "$fd" ] && [ "$ed" != "$fd" ]; then echo "OK   7 LPAD(s, -1) describe (recorded: engine [$ed], this server [$fd])"
elif [ "$ed" = "$fd" ]; then echo "FAIL 7 LPAD(s, -1) describe now agrees; promote the cell"; fail=1
else echo "FAIL 7 LPAD(s, -1) describe: eng=[$ed] fc=[$fd]"; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-fnargs-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 173 ]; then echo "FAIL only $ran checks ran (floor 173)"; fail=1; fi
exit $fail
