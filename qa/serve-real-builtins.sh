#!/bin/bash
# THE MISSING BUILT-INS AND THE ARGUMENT COERCIONS OF sysfn_named.
#
# Measured on engine 2182 (LI-T6.0.0.2182) before each was written; every
# cell that is not a CONTROL or RECORDED answered differently here before
# (a bare 42000 *Dynamic SQL Error* refusal for almost all of them):
#
#   * ACOSH / ASINH / ATANH by evlStdMath's own formulas (so ASINH(-1e308)
#     overflows as the engine's `log(v + sqrt(v*v + 1))` does), their
#     domain errors and the named float overflow; the std-math family
#     also reads a DECFLOAT operand as a double now;
#   * a SysFunction table entry called with the wrong argument count is
#     39000 *function X could not be matched* at prepare (ABS(), LEFT('a'),
#     PI(1), POSITION with four, ...);
#   * ASCII_CHAR (CHAR(1) NONE), UNICODE_CHAR (CHAR(1) UTF8), UNICODE_VAL
#     (INTEGER), with their range / domain / Malformed errors;
#   * MAXVALUE / MINVALUE / GREATEST / LEAST: lowered to the searched CASE
#     that answers what evlMaxMinValue does - makeFromList's describe and
#     nullability, the comparison on the arguments as they are, a NULL
#     anywhere NULL, HY004 for two datetime kinds;
#   * DECODE in a WHERE (the predicate tokenizer read it as a column);
#   * SIGN / MOD over a text, MOD over a DECFLOAT (MOV_get_int64, INT64),
#     ASCII_VAL / UNICODE_VAL / CRYPT_HASH over a number (its text form),
#     DATEADD over a NULL (CHAR(1) NONE) or a text operand (its own text
#     type, then the per-row *Invalid data type in addition of part*);
#   * HEX_ENCODE / HEX_DECODE / BASE64_ENCODE / BASE64_DECODE over the
#     operand's stored bytes, their prepare-time length / type errors and
#     libtomcrypt's relaxed base64 decoder; UUID_TO_CHAR / CHAR_TO_UUID
#     with every argument check; CRYPT_HASH (MD5, SHA1, SHA256, SHA512,
#     SHA3_224/256/384/512); OVERLAY with its #3 / #4 errors;
#   * LISTAGG is LIST (header and blob), and WITHIN GROUP (ORDER BY ...)
#     orders the join - ASC/DESC, NULLS FIRST/LAST, several keys;
#   * a scaled literal past INT64 is an INT128 NUMERIC(38, s) CONSTANT
#     (past INT128 a DECFLOAT(34)), so CAST(<33 digits>.123 AS
#     NUMERIC(38,3)) and CAST(<19 digits>.5 AS DECFLOAT(34)) answer.
#
# Section 14 is the review of that round: LISTAGG's ties on the WITHIN
# GROUP key go by the rest of the engine's sort record (the aggregated
# value's native words), not by row order; MAXVALUE over a zoned and a
# zone-less datetime is one kind (the zone-less one CAST to the zoned
# type); a DECFLOAT past the double's range is the conversion's bare
# 22003 float overflow in the std-math family and the CAST to DOUBLE,
# and a text whose decimal scale is past 308 is 22003 *numeric value is
# out of range* (CVT_get_double); CRYPT_HASH / UNICODE_VAL / the UUID
# pair over a BLOB describe their own types, and the functions that
# read a NUMBER raise 22018 *conversion error from string "BLOB"* over
# one; a literal CAST to a UTF8 text blob is its characters.
#
# Section 15 is the review of the merged round: every double literal of
# an item whose own type is DECFLOAT (a COALESCE / CASE / IIF / DECODE /
# MAXVALUE, an arithmetic over one, a condition inside it) is read from
# its text at that width, as the assignment's preferred descriptor makes
# the engine do; HEX_ / BASE64_DECODE over a blob is a BLOB SUB_TYPE
# BINARY with the length checked per row, the encoders over one a text
# blob in ASCII; a DECFLOAT(16) NaN is equal to every number (a
# DECFLOAT(34) side raises 22000), so MAXVALUE keeps a first-argument NaN
# and passes a later one over; ASCII_VAL / UNICODE_VAL move a blob into a
# string (22001 past 32767 bytes); UNICODE_VAL of bytes that are no
# UTF-8 is the bare 22000 Malformed string; an INT128 of more than 34
# digits has no DECFLOAT(34) (22000); a blob at a NUMBER position of LPAD
# / LEFT / SUBSTRING's FOR / DATEADD / OVERLAY / POSITION describes as a
# text there and raises 22018 "BLOB".
#
# RECORDED (clean refusals kept): SUBSTRING ... SIMILAR, BLOB_APPEND, CAST
# ... FORMAT, MAXVALUE of a number beside a non-numeric text (the engine
# prepares and raises 22018 per row) or of a DATE beside a text (VARCHAR),
# a HAVING over any conditional, and an intrinsic's extra argument (the
# engine's -104 *Token unknown*); and from section 14 MAXVALUE of a
# number beside two texts (not transitive - the engine's left-to-right
# scan is not the lowered CASE's), of two texts in two real character
# sets (the engine transliterates and raises), and nested past the
# lowering's budget (twelve deep); from section 15 a signalling or
# negative NaN literal cast, SUBSTRING FROM a blob (the engine's -607 at
# prepare) and ROUND's places from a blob.
#
# Usage: qa/serve-real-builtins.sh [port]   (default 5770)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5770}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/builtins-eng.fdb"; FC="$D/builtins-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER NOT NULL, N INTEGER NOT NULL, V VARCHAR(20), C CHAR(5), U VARCHAR(10) CHARACTER SET UTF8,
  W VARCHAR(10) CHARACTER SET WIN1252, NM NUMERIC(10,2), DB DOUBLE PRECISION, DF DECFLOAT(16), D34 DECFLOAT(34),
  I128 INT128, D DATE, TS TIMESTAMP, B64 VARCHAR(20), HX VARCHAR(20), G INTEGER, K INTEGER, SI SMALLINT);
INSERT INTO T VALUES (1, 7, 'b', 'ab', 'é', 'é', 1.50, 2.5, 3.25, 7.5, 5, '2024-01-01', '2024-01-01 10:00:00', 'YWJj', '616263', 1, 3, 4);
INSERT INTO T VALUES (2, 8, 'a', 'Q', 'ω', 'x', NULL, -1, -7.5, 2, -3, '2023-05-05', NULL, 'YWJjZA', '6G', 1, 1, -2);
INSERT INTO T VALUES (3, 9, 'c', NULL, NULL, NULL, 3.00, 0, 0, 0, 170141183460469231731687303715884105727, NULL, NULL, 'YW', 'ABC', 2, 2, 0);
INSERT INTO T VALUES (4, 10, NULL, 'xyz', 'ab', 'ab', 2.25, 0.5, 2, 3, 7, '2024-02-29', '2024-02-29 00:00:00', '', '', 2, NULL, 1);
INSERT INTO T VALUES (5, 11, 'd', 'z', 'z', 'z', 0.01, 1, 1, 1, 1, '2020-01-01', '2020-01-01 00:00:00', 'Y===', '0a0B', 1, NULL, 3);
CREATE TABLE TB (ID INTEGER NOT NULL, BL BLOB SUB_TYPE TEXT, BU BLOB SUB_TYPE TEXT CHARACTER SET UTF8, BB BLOB SUB_TYPE BINARY);
INSERT INTO TB VALUES (1, 'blobv', 'éa', 'abc');
INSERT INTO TB VALUES (2, NULL, NULL, NULL);
CREATE TABLE TN (ID INTEGER NOT NULL, A DECFLOAT(16), B DECFLOAT(34), I INTEGER, X DOUBLE PRECISION, I8 INT128);
INSERT INTO TN VALUES (1, 'NaN', 1, 1, 1, 1);
INSERT INTO TN VALUES (2, 1, 'NaN', 1, 1, 1);
INSERT INTO TN VALUES (3, 5, 2, 5, 5, 5);
CREATE TABLE TC (ID INTEGER NOT NULL, BT BLOB SUB_TYPE TEXT, BN BLOB SUB_TYPE BINARY, BU BLOB SUB_TYPE TEXT CHARACTER SET UTF8);
INSERT INTO TC VALUES (1, '4142', x'4142', '4142');
INSERT INTO TC VALUES (2, 'QUJD', x'0102', 'QUJD');
INSERT INTO TC VALUES (3, '414', x'414243', 'QUJ');
INSERT INTO TC VALUES (4, '', x'', '');
INSERT INTO TC VALUES (5, NULL, NULL, NULL);
COMMIT;
INSERT INTO TC SELECT 6, CAST(LPAD('', 32765, 'a') AS BLOB SUB_TYPE TEXT) || 'aa', CAST(LPAD('', 32765, 'a') AS BLOB SUB_TYPE TEXT) || 'aa',
  CAST(LPAD('', 32765, 'a') AS BLOB SUB_TYPE TEXT) || 'aa' FROM RDB$DATABASE;
INSERT INTO TC SELECT 7, CAST(LPAD('', 32765, 'a') AS BLOB SUB_TYPE TEXT) || 'aaa', CAST(LPAD('', 32765, 'a') AS BLOB SUB_TYPE TEXT) || 'aaa',
  CAST(LPAD('', 32765, 'a') AS BLOB SUB_TYPE TEXT) || 'aaa' FROM RDB$DATABASE;
INSERT INTO TC SELECT 8, CAST(LPAD('', 30000, 'x') AS BLOB SUB_TYPE TEXT) || LPAD('', 30000, 'y') || LPAD('', 10000, 'z'), NULL, NULL FROM RDB$DATABASE;
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/builtins-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/builtins-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/builtins-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-builtins-$PORT.log" 2>&1 & srv=$!
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
sess() { printf '%s\n' "$2" | timeout -s KILL 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# ...through a UTF8 attachment
sessu() { printf '%s\n' "$2" | timeout -s KILL 25 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# ...with a blob's CONTENT shown and its id (which no two servers share)
# masked
sessb() { printf 'SET BLOB ALL;\n%s\n' "$2" | timeout -s KILL 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' \
    | sed -E 's/\b[0-9a-f]+:[0-9a-f]+\b/<blob>/g' | grep -av '^BLOB display set to' | paste -sd'|'; }
# the describe: type, length, charset, nullability, name
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout -s KILL 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -aE 'sqltype|name:|Statement failed|SQLSTATE' | sed 's/  */ /g' | paste -sd'|'; }
# ...through a UTF8 attachment
dscu() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout -s KILL 25 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -aE 'sqltype|name:|Statement failed|SQLSTATE' | sed 's/  */ /g' | paste -sd'|'; }
check() { # <label> <engine> <fc> <pinned>
    ran=$((ran + 1))
    if [ "$2" != "$4" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$2], not the pinned [$4]"; fail=1
    elif [ "$2" != "$3" ]; then echo "FAIL $1"; echo "     eng=[$2]"; echo "     fc =[$3]"; fail=1
    else echo "OK   $1 [$2]"; fi
}
# the engine is pinned, and this server agrees with it
pin()  { check "$1" "$(sess  "127.0.0.1/$REAL:$ENG" "$2")" "$(sess  "127.0.0.1/$PORT:$FC" "$2")" "$3"; }
pinu() { check "$1" "$(sessu "127.0.0.1/$REAL:$ENG" "$2")" "$(sessu "127.0.0.1/$PORT:$FC" "$2")" "$3"; }
pinb() { check "$1" "$(sessb "127.0.0.1/$REAL:$ENG" "$2")" "$(sessb "127.0.0.1/$PORT:$FC" "$2")" "$3"; }
dpin() { check "$1" "$(dsc   "127.0.0.1/$REAL:$ENG" "$2")" "$(dsc   "127.0.0.1/$PORT:$FC" "$2")" "$3"; }
dpinu() { check "$1" "$(dscu "127.0.0.1/$REAL:$ENG" "$2")" "$(dscu "127.0.0.1/$PORT:$FC" "$2")" "$3"; }
# a RECORDED difference: the engine's answer is pinned, and this server
# must still give its known clean refusal - a cell that starts to agree
# FAILS, so it is promoted rather than left behind
rec() { # <label> <script> <engine-output> <this-server-output> [session fn]
    ran=$((ran + 1))
    local ev fv f="${5:-sess}"
    ev=$($f "127.0.0.1/$REAL:$ENG" "$2"); fv=$($f "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server answers [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: engine [$ev], this server [$fv])"; fi
}

echo '--- 1. ACOSH / ASINH / ATANH: evlStdMath'"'"'s formulas, its domain checks, its overflow'
pin  '1 ACOSH(2) ASINH(1) ATANH(0.5)' 'SELECT ACOSH(2), ASINH(1), ATANH(0.5) FROM RDB$DATABASE;' \
     'ACOSH ASINH ATANH|1.316957896924817 0.8813735870195429 0.5493061443340549'
dpin '1 describe: DOUBLE, a NULL operand nullable' 'SELECT ACOSH(2), ASINH(NULL), ATANH(DB) FROM T WHERE ID = 1;' \
     '01: sqltype: 480 DOUBLE scale: 0 subtype: 0 len: 8| : name: ACOSH alias: ACOSH|02: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8| : name: ASINH alias: ASINH|03: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8| : name: ATANH alias: ATANH|Statement failed, SQLSTATE = 42000'
pin  '1 ACOSH(1) is 0, ASINH(0) 0, ATANH(0) 0' 'SELECT ACOSH(1), ASINH(0), ATANH(0) FROM RDB$DATABASE;' \
     'ACOSH ASINH ATANH|0.000000000000000 0.000000000000000 0.000000000000000'
pin  '1 negatives' 'SELECT ASINH(-2), ATANH(-0.25) FROM RDB$DATABASE;' \
     'ASINH ATANH|-1.443635475178810 -0.2554128118829954'
pin  '1 ACOSH below one raises its domain error' 'SELECT ACOSH(0.5) FROM RDB$DATABASE;' \
     'ACOSH|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for ACOSH must be greater or equal than one'
pin  '1 ATANH(1) raises' 'SELECT ATANH(1) FROM RDB$DATABASE;' \
     'ATANH|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for ATANH must be in the range ]-1, 1['
pin  '1 ATANH(-1) raises' 'SELECT ATANH(-1) FROM RDB$DATABASE;' \
     'ATANH|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for ATANH must be in the range ]-1, 1['
pin  '1 ATANH(2) raises' 'SELECT ATANH(2) FROM RDB$DATABASE;' \
     'ATANH|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for ATANH must be in the range ]-1, 1['
pin  '1 ASINH(-1e308): the engine'"'"'s formula overflows' 'SELECT ASINH(-1e308) FROM RDB$DATABASE;' \
     'ASINH|Statement failed, SQLSTATE = 42000|arithmetic exception, numeric overflow, or string truncation|-Floating point overflow in built-in function ASINH'
pin  '1 ASINH(1e200) overflows too (v*v)' 'SELECT ASINH(1e200) FROM RDB$DATABASE;' \
     'ASINH|Statement failed, SQLSTATE = 42000|arithmetic exception, numeric overflow, or string truncation|-Floating point overflow in built-in function ASINH'
pin  '1 a text operand converts, a NULL answers NULL' 'SELECT ASINH('"'"'1'"'"'), ACOSH(NULL), ATANH('"'"'0.5'"'"') FROM RDB$DATABASE;' \
     'ASINH ACOSH ATANH|0.8813735870195429 <null> 0.5493061443340549'
pin  '1 a non-numeric text is 22018' 'SELECT ACOSH('"'"'abc'"'"') FROM RDB$DATABASE;' \
     'ACOSH|Statement failed, SQLSTATE = 22018|conversion error from string "abc"'
pin  '1 a DECFLOAT operand reads as a double' 'SELECT ACOSH(CAST(2 AS DECFLOAT(16))), ASINH(DF) FROM T WHERE ID = 1;' \
     'ACOSH ASINH|1.316957896924817 1.894672135423041'
pin  '1 over columns' 'SELECT ID, ASINH(NM), ATANH(DB / 4) FROM T WHERE ID IN (1, 4, 5) ORDER BY ID;' \
     'ID ASINH ATANH|1 1.194763217287109 0.7331685343967135|4 1.550157956869062 0.1256572141404531|5 0.009999833340832797 0.2554128118829954'
pin  '1 in a WHERE' 'SELECT ID FROM T WHERE ACOSH(N) > 2.8 ORDER BY ID;' \
     'ID|3|4|5'
pin  '1 the domain error is per row' 'SELECT ID, ATANH(DB) FROM T ORDER BY ID;' \
     'ID ATANH|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for ATANH must be in the range ]-1, 1['
pin  'CONTROL 1 SINH/COSH/TANH unchanged' 'SELECT SINH(1), COSH(1), TANH(1) FROM RDB$DATABASE;' \
     'SINH COSH TANH|1.175201193643801 1.543080634815244 0.7615941559557649'
echo '--- 2. A table function called with the wrong argument count is 39000 at prepare'
pin  '2 ACOSH(1, 2)' 'SELECT ACOSH(1, 2) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function ACOSH could not be matched'
pin  '2 ACOSH()' 'SELECT ACOSH() FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function ACOSH could not be matched'
pin  '2 ABS()' 'SELECT ABS() FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function ABS could not be matched'
pin  '2 LEFT('"'"'a'"'"')' 'SELECT LEFT('"'"'a'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function LEFT could not be matched'
pin  '2 PI(1)' 'SELECT PI(1) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function PI could not be matched'
pin  '2 MOD(1)' 'SELECT MOD(1) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function MOD could not be matched'
pin  '2 MAXVALUE()' 'SELECT MAXVALUE() FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function MAXVALUE could not be matched'
pin  '2 POSITION with four arguments' 'SELECT POSITION('"'"'a'"'"', '"'"'b'"'"', '"'"'c'"'"', '"'"'d'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function POSITION could not be matched'
pin  '2 RDB$GET_CONTEXT with one' 'SELECT RDB$GET_CONTEXT('"'"'SYSTEM'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function RDB$GET_CONTEXT could not be matched'
pin  '2 BIN_AND with one' 'SELECT BIN_AND(1) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function BIN_AND could not be matched'
pin  '2 ASCII_VAL with two' 'SELECT ASCII_VAL(1, 2) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function ASCII_VAL could not be matched'
pin  '2 ASCII_CHAR with two' 'SELECT ASCII_CHAR(65, 66) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function ASCII_CHAR could not be matched'
pin  '2 LPAD with four' 'SELECT LPAD('"'"'a'"'"', 3, '"'"'b'"'"', '"'"'c'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function LPAD could not be matched'
pin  '2 UNICODE_VAL()' 'SELECT UNICODE_VAL() FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 39000|function UNICODE_VAL could not be matched'
pin  '2 ... in a WHERE' 'SELECT ID FROM T WHERE ABS(ID, 1) = 1;' \
     'Statement failed, SQLSTATE = 39000|function ABS could not be matched'
pin  'CONTROL 2 the right counts answer' 'SELECT ABS(-1), LEFT('"'"'ab'"'"', 1), PI(), MOD(7, 3) FROM RDB$DATABASE;' \
     'ABS LEFT PI MOD|1 a 3.141592653589793 1'
rec  '2 RECORDED an intrinsic'"'"'s extra argument is the engine'"'"'s -104 Token unknown' 'SELECT UPPER('"'"'a'"'"', '"'"'b'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 17|-,' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo '--- 3. ASCII_CHAR / UNICODE_CHAR / UNICODE_VAL'
pin  '3 ASCII_CHAR(65)' 'SELECT ASCII_CHAR(65) FROM RDB$DATABASE;' \
     'ASCII_CHAR|A'
dpin '3 describe: CHAR(1) NONE, NULL operand CHAR(1) NONE nullable' 'SELECT ASCII_CHAR(65), ASCII_CHAR(NULL), ASCII_CHAR(N) FROM T WHERE ID = 1;' \
     '01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: ASCII_CHAR alias: ASCII_CHAR|02: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: ASCII_CHAR alias: ASCII_CHAR|03: sqltype: 452 TEXT scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: ASCII_CHAR alias: ASCII_CHAR'
pin  '3 ASCII_CHAR rounds its code and reads a text one' 'SELECT ASCII_CHAR(65.7), ASCII_CHAR('"'"'66'"'"'), ASCII_CHAR(66.4) FROM RDB$DATABASE;' \
     'ASCII_CHAR ASCII_CHAR ASCII_CHAR|B B B'
pin  '3 ASCII_CHAR(0) is one zero byte, NULL is NULL' 'SELECT OCTET_LENGTH(ASCII_CHAR(0)), ASCII_VAL(ASCII_CHAR(0)), ASCII_CHAR(NULL) FROM RDB$DATABASE;' \
     'OCTET_LENGTH ASCII_VAL ASCII_CHAR|1 0 <null>'
pin  '3 ASCII_CHAR(256) is 22003' 'SELECT ASCII_CHAR(256) FROM RDB$DATABASE;' \
     'ASCII_CHAR|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin  '3 ASCII_CHAR(-1) is 22003' 'SELECT ASCII_CHAR(-1) FROM RDB$DATABASE;' \
     'ASCII_CHAR|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin  '3 ASCII_CHAR of a column, in a WHERE' 'SELECT ID, ASCII_CHAR(N + 90) FROM T WHERE ASCII_CHAR(N + 90) > '"'"'b'"'"' ORDER BY ID;' \
     'ID ASCII_CHAR|3 c|4 d|5 e'
pin  '3 ASCII_CHAR(200) is one NONE byte' 'SELECT OCTET_LENGTH(ASCII_CHAR(200)), ASCII_VAL(ASCII_CHAR(200)) FROM RDB$DATABASE;' \
     'OCTET_LENGTH ASCII_VAL|1 200'
pin  '3 UNICODE_CHAR(233), (65), NULL' 'SELECT UNICODE_CHAR(233), UNICODE_CHAR(65) || '"'"'|'"'"', UNICODE_CHAR(NULL) FROM RDB$DATABASE;' \
     'UNICODE_CHAR CONCATENATION UNICODE_CHAR|é A| <null>'
dpin '3 describe: CHAR(1) UTF8 (4 bytes), NULL operand CHAR(1) NONE' 'SELECT UNICODE_CHAR(233), UNICODE_CHAR(NULL) FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 4 charset: 4 SYSTEM.UTF8| : name: UNICODE_CHAR alias: UNICODE_CHAR|02: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: UNICODE_CHAR alias: UNICODE_CHAR'
pin  '3 UNICODE_CHAR of a negative is its domain error' 'SELECT UNICODE_CHAR(-1) FROM RDB$DATABASE;' \
     'UNICODE_CHAR|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for UNICODE_CHAR must be zero or positive'
pin  '3 UNICODE_CHAR of a surrogate is Malformed' 'SELECT UNICODE_CHAR(55296) FROM RDB$DATABASE;' \
     'UNICODE_CHAR|Statement failed, SQLSTATE = 22000|arithmetic exception, numeric overflow, or string truncation|-Malformed string'
pin  '3 UNICODE_CHAR past U+10FFFF is Malformed' 'SELECT UNICODE_CHAR(1114112) FROM RDB$DATABASE;' \
     'UNICODE_CHAR|Statement failed, SQLSTATE = 22000|arithmetic exception, numeric overflow, or string truncation|-Malformed string'
pin  '3 UNICODE_CHAR of a 4-byte character' 'SELECT OCTET_LENGTH(UNICODE_CHAR(128512)), CHAR_LENGTH(UNICODE_CHAR(128512)) FROM RDB$DATABASE;' \
     'OCTET_LENGTH CHAR_LENGTH|4 1'
pinu '3 UNICODE_CHAR under a UTF8 attachment' 'SELECT UNICODE_CHAR(969), UNICODE_CHAR(66) || '"'"'|'"'"' FROM RDB$DATABASE;' \
     'UNICODE_CHAR CONCATENATION|ω B|'
dpinu '3 describes under UTF8' 'SELECT UNICODE_CHAR(969), ASCII_CHAR(65), UNICODE_VAL('"'"'x'"'"') FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 4 charset: 4 SYSTEM.UTF8| : name: UNICODE_CHAR alias: UNICODE_CHAR|02: sqltype: 452 TEXT scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: ASCII_CHAR alias: ASCII_CHAR|03: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: UNICODE_VAL alias: UNICODE_VAL'
pin  '3 UNICODE_VAL('"'"'é'"'"'), ('"'"''"'"'), NULL' 'SELECT UNICODE_VAL('"'"'A'"'"'), UNICODE_VAL('"'"''"'"'), UNICODE_VAL(NULL) FROM RDB$DATABASE;' \
     'UNICODE_VAL UNICODE_VAL UNICODE_VAL|65 0 <null>'
dpin '3 describe: INTEGER' 'SELECT UNICODE_VAL('"'"'A'"'"'), UNICODE_VAL(NULL), UNICODE_VAL(U) FROM T WHERE ID = 1;' \
     '01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: UNICODE_VAL alias: UNICODE_VAL|02: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: UNICODE_VAL alias: UNICODE_VAL|03: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: UNICODE_VAL alias: UNICODE_VAL'
pin  '3 UNICODE_VAL of a number reads its text' 'SELECT UNICODE_VAL(5), UNICODE_VAL(12.5), UNICODE_VAL(-1) FROM RDB$DATABASE;' \
     'UNICODE_VAL UNICODE_VAL UNICODE_VAL|53 49 45'
pin  '3 UNICODE_VAL over UTF8 and WIN1252 columns' 'SELECT ID, UNICODE_VAL(U), UNICODE_VAL(W) FROM T ORDER BY ID;' \
     'ID UNICODE_VAL UNICODE_VAL|1 233 195|2 969 120|3 <null> <null>|4 97 97|5 122 122'
pinu '3 UNICODE_VAL of a UTF8 literal' 'SELECT UNICODE_VAL('"'"'é'"'"'), UNICODE_VAL('"'"'ωx'"'"') FROM RDB$DATABASE;' \
     'UNICODE_VAL UNICODE_VAL|233 969'
pin  '3 UNICODE_VAL of a NONE literal reads its bytes as UTF-8' 'SELECT UNICODE_VAL('"'"'é'"'"') FROM RDB$DATABASE;' \
     'UNICODE_VAL|233'
pin  '3 UNICODE_VAL in a WHERE' 'SELECT ID FROM T WHERE UNICODE_VAL(V) = 98;' \
     'ID|1'
echo '--- 4. MAXVALUE / MINVALUE / GREATEST / LEAST'
pin  '4 MAXVALUE(1, 5, 3), MINVALUE(1, 5, 3)' 'SELECT MAXVALUE(1, 5, 3), MINVALUE(1, 5, 3) FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE|5 1'
pin  '4 any NULL is NULL' 'SELECT MAXVALUE(1, NULL, 3), MINVALUE(NULL, 2) FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE|<null> <null>'
dpin '4 describe: LONG, nullable only beside a NULL' 'SELECT MAXVALUE(1, 5, 3), MAXVALUE(1, NULL, 3) FROM RDB$DATABASE;' \
     '01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: MAXVALUE alias: MAXVALUE|02: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: MAXVALUE alias: MAXVALUE'
dpin '4 describe: a scaled one INT64 -1, a double DOUBLE, text CHAR(2)' 'SELECT MAXVALUE(1, 2.5), MAXVALUE(1, 2e0), MAXVALUE('"'"'a'"'"', '"'"'bc'"'"') FROM RDB$DATABASE;' \
     '01: sqltype: 580 INT64 scale: -1 subtype: 0 len: 8| : name: MAXVALUE alias: MAXVALUE|02: sqltype: 480 DOUBLE scale: 0 subtype: 0 len: 8| : name: MAXVALUE alias: MAXVALUE|03: sqltype: 452 TEXT scale: 0 subtype: 0 len: 2 charset: 0 SYSTEM.NONE| : name: MAXVALUE alias: MAXVALUE'
pin  '4 the values' 'SELECT MAXVALUE(1, 2.5), MAXVALUE(1, 2e0), MAXVALUE('"'"'a'"'"', '"'"'bc'"'"'), MINVALUE('"'"'a'"'"', '"'"'bc'"'"') || '"'"'|'"'"' FROM RDB$DATABASE;' \
     'MAXVALUE MAXVALUE MAXVALUE CONCATENATION|2.5 2.000000000000000 bc a |'
pin  '4 dates' 'SELECT MINVALUE(DATE '"'"'2024-01-01'"'"', DATE '"'"'2023-01-01'"'"'), MAXVALUE(DATE '"'"'2024-01-01'"'"', DATE '"'"'2023-01-01'"'"') FROM RDB$DATABASE;' \
     'MINVALUE MAXVALUE|2023-01-01 2024-01-01'
pin  '4 one argument' 'SELECT MAXVALUE(5), MINVALUE('"'"'x'"'"') FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE|5 x'
pin  '4 GREATEST / LEAST are the same functions' 'SELECT GREATEST(1, 2), LEAST(1, 2), LEAST(1, 2, NULL), GREATEST(3) FROM RDB$DATABASE;' \
     'GREATEST LEAST LEAST GREATEST|2 1 <null> 3'
dpin '4 GREATEST / LEAST headers' 'SELECT GREATEST(1, 2), LEAST(1, 2) FROM RDB$DATABASE;' \
     '01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: GREATEST alias: GREATEST|02: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: LEAST alias: LEAST'
pin  '4 a number against a text compares as numbers' 'SELECT MAXVALUE(9, '"'"'10'"'"'), MINVALUE(9, '"'"'10'"'"') FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE|10 9'
dpin '4 ... and describes VARCHAR(11)' 'SELECT MAXVALUE(1, '"'"'7'"'"') FROM RDB$DATABASE;' \
     '01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 11 charset: 0 SYSTEM.NONE| : name: MAXVALUE alias: MAXVALUE'
pin  '4 text is compared by bytes' 'SELECT MAXVALUE('"'"'b'"'"', '"'"'B'"'"', '"'"'a'"'"'), MINVALUE('"'"'b'"'"', '"'"'B'"'"', '"'"'a'"'"') FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE|b B'
pin  '4 over mixed columns: the DOUBLE of the winner' 'SELECT ID, MAXVALUE(ID, NM, DB) FROM T ORDER BY ID;' \
     'ID MAXVALUE|1 2.500000000000000|2 <null>|3 3.000000000000000|4 4.000000000000000|5 5.000000000000000'
dpin '4 describe over mixed columns: DOUBLE nullable' 'SELECT MAXVALUE(ID, NM, DB) FROM T;' \
     '01: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8| : name: MAXVALUE alias: MAXVALUE'
pin  '4 a NOT NULL column stays NOT NULL' 'SELECT MAXVALUE(N, 1) FROM T ORDER BY ID;' \
     'MAXVALUE|7|8|9|10|11'
dpin '4 describe over a NOT NULL column' 'SELECT MAXVALUE(N, 1), MAXVALUE(N, ID) FROM T;' \
     '01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: MAXVALUE alias: MAXVALUE|02: sqltype: 496 LONG scale: 0 subtype: 0 len: 4| : name: MAXVALUE alias: MAXVALUE'
pin  '4 text columns' 'SELECT ID, MINVALUE(V, '"'"'b'"'"') FROM T ORDER BY ID;' \
     'ID MINVALUE|1 b|2 a|3 b|4 <null>|5 b'
dpin '4 text column describe' 'SELECT MINVALUE(V, '"'"'b'"'"') FROM T;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 0 SYSTEM.NONE| : name: MINVALUE alias: MINVALUE'
pin  '4 SMALLINT / BIGINT / INT128 widths' 'SELECT MAXVALUE(CAST(1 AS SMALLINT), CAST(2 AS SMALLINT)), MAXVALUE(CAST(1 AS BIGINT), 2), MAXVALUE(1, CAST(2 AS INT128)) FROM RDB$DATABASE;' \
     'MAXVALUE MAXVALUE MAXVALUE|2 2 2'
dpin '4 SMALLINT / BIGINT / INT128 describe' 'SELECT MAXVALUE(CAST(1 AS SMALLINT), CAST(2 AS SMALLINT)), MAXVALUE(CAST(1 AS BIGINT), 2), MAXVALUE(1, CAST(2 AS INT128)) FROM RDB$DATABASE;' \
     '01: sqltype: 500 SHORT scale: 0 subtype: 0 len: 2| : name: MAXVALUE alias: MAXVALUE|02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8| : name: MAXVALUE alias: MAXVALUE|03: sqltype: 32752 INT128 scale: 0 subtype: 0 len: 16| : name: MAXVALUE alias: MAXVALUE'
pin  '4 a DECFLOAT beside a NUMERIC' 'SELECT ID, MAXVALUE(NM, DF) FROM T ORDER BY ID;' \
     'ID MAXVALUE|1 3.25|2 <null>|3 3.00|4 2.25|5 1'
dpin '4 a DECFLOAT beside a NUMERIC describes DECFLOAT(16)' 'SELECT MAXVALUE(NM, DF) FROM T;' \
     '01: sqltype: 32760 DECFLOAT(16) Nullable scale: 0 subtype: 0 len: 8| : name: MAXVALUE alias: MAXVALUE'
pin  '4 ties keep the first argument'"'"'s value' 'SELECT MAXVALUE(2, 2.0), MAXVALUE(2.00, 2) FROM RDB$DATABASE;' \
     'MAXVALUE MAXVALUE|2.0 2.00'
pin  '4 in a WHERE' 'SELECT ID FROM T WHERE 1 = MAXVALUE(1, 0) AND MAXVALUE(ID, 2) = 2 ORDER BY ID;' \
     'ID|1|2'
pin  '4 in a WHERE over a column' 'SELECT ID FROM T WHERE MINVALUE(ID, K) = 1 ORDER BY ID;' \
     'ID|1|2'
pin  '4 inside arithmetic and a CAST' 'SELECT MAXVALUE(1, 5) * 2, CAST(MINVALUE(3, 4) AS VARCHAR(5)) || '"'"'|'"'"' FROM RDB$DATABASE;' \
     'MULTIPLY CONCATENATION|10 3|'
pin  '4 in GROUP BY / aggregate' 'SELECT G, MAX(MAXVALUE(ID, K)) FROM T GROUP BY G ORDER BY G;' \
     'G MAX|1 3|2 3'
pin  '4 a TIMESTAMP beside a DATE is HY004' 'SELECT MINVALUE(TIMESTAMP '"'"'2024-01-01 10:00:00'"'"', DATE '"'"'2024-01-01'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression MINVALUE'
pin  '4 ... over columns too' 'SELECT MAXVALUE(D, TS) FROM T;' \
     'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression MAXVALUE'
rec  '4 RECORDED a non-numeric text beside a number: the engine raises 22018 per row' 'SELECT MAXVALUE(1, '"'"'x'"'"') FROM RDB$DATABASE;' \
     'MAXVALUE|Statement failed, SQLSTATE = 22018|conversion error from string "x"' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
rec  '4 RECORDED a DATE beside a text: the engine answers VARCHAR' 'SELECT MAXVALUE(DATE '"'"'2024-01-01'"'"', '"'"'2025-01-01'"'"') FROM RDB$DATABASE;' \
     'MAXVALUE|2025-01-01' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo '--- 5. DECODE in a WHERE'
pin  '5 WHERE DECODE(1, 1, '"'"'a'"'"') = '"'"'a'"'"'' 'SELECT 1 FROM RDB$DATABASE WHERE DECODE(1, 1, '"'"'a'"'"') = '"'"'a'"'"';' \
     'CONSTANT|1'
pin  '5 over a column' 'SELECT ID FROM T WHERE DECODE(ID, 2, 1, 0) = 1;' \
     'ID|2'
pin  '5 on the right side' 'SELECT ID FROM T WHERE 1 = DECODE(ID, 2, 1, 3, 1, 0) ORDER BY ID;' \
     'ID|2|3'
pin  '5 under arithmetic' 'SELECT ID FROM T WHERE DECODE(ID, 2, 1, 0) + 0 = 1;' \
     'ID|2'
pin  '5 no default: an unmatched row is NULL' 'SELECT ID FROM T WHERE DECODE(G, 2, '"'"'x'"'"') IS NULL ORDER BY ID;' \
     'ID|1|2|5'
pin  '5 in AND / OR' 'SELECT ID FROM T WHERE DECODE(G, 1, K, 0) > 1 OR ID = 4 ORDER BY ID;' \
     'ID|1|4'
pin  '5 in an UPDATE WHERE' 'UPDATE T SET K = K WHERE DECODE(ID, 3, 1, 0) = 1; SELECT COUNT(*) FROM T WHERE DECODE(ID, 3, 1, 0) = 1;' \
     'COUNT|1'
rec  '5 RECORDED a HAVING over any conditional (DECODE, IIF, COALESCE alike) still refuses' 'SELECT G, COUNT(*) FROM T GROUP BY G HAVING DECODE(G, 1, 1, 0) = 1;' \
     'G COUNT|1 3' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin  'CONTROL 5 IIF in a WHERE' 'SELECT ID FROM T WHERE IIF(ID = 2, 1, 0) = 1;' \
     'ID|2'
echo '--- 6. The argument coercions: SIGN / MOD / ASCII_VAL / DATEADD'
pin  '6 SIGN of a text' 'SELECT SIGN('"'"'5'"'"'), SIGN('"'"'-2.5'"'"'), SIGN('"'"'0'"'"') FROM RDB$DATABASE;' \
     'SIGN SIGN SIGN|1 -1 0'
pin  '6 SIGN of a non-numeric text is 22018' 'SELECT SIGN('"'"'abc'"'"') FROM RDB$DATABASE;' \
     'SIGN|Statement failed, SQLSTATE = 22018|conversion error from string "abc"'
dpin '6 SIGN(text) describes SHORT' 'SELECT SIGN('"'"'5'"'"'), SIGN(NULL) FROM RDB$DATABASE;' \
     '01: sqltype: 500 SHORT scale: 0 subtype: 0 len: 2| : name: SIGN alias: SIGN|02: sqltype: 500 SHORT Nullable scale: 0 subtype: 0 len: 2| : name: SIGN alias: SIGN'
pin  '6 MOD over a DECFLOAT column' 'SELECT ID, MOD(DF, 2) FROM T ORDER BY ID;' \
     'ID MOD|1 1|2 0|3 0|4 0|5 1'
dpin '6 MOD over a DECFLOAT is INT64, MOD(int, df) the int'"'"'s' 'SELECT MOD(DF, 2), MOD(7, DF), MOD(N, DF) FROM T WHERE ID = 1;' \
     '01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8| : name: MOD alias: MOD|02: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: MOD alias: MOD|03: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: MOD alias: MOD'
pin  '6 MOD rounds a DECFLOAT half up' 'SELECT MOD(CAST(7.5 AS DECFLOAT(34)), CAST(2 AS DECFLOAT(16))), MOD(CAST(-7 AS DECFLOAT(16)), 3), MOD(7, CAST(2 AS DECFLOAT(16))) FROM RDB$DATABASE;' \
     'MOD MOD MOD|0 -1 1'
pin  '6 MOD by a DECFLOAT zero' 'SELECT MOD(DF, 0) FROM T WHERE ID = 1;' \
     'MOD|Statement failed, SQLSTATE = 22012|arithmetic exception, numeric overflow, or string truncation|-Integer divide by zero. The code attempted to divide an integer value by an integer divisor of zero.'
pin  '6 MOD of a text' 'SELECT MOD('"'"'7'"'"', 2), MOD('"'"'7.5'"'"', 2), MOD(9, '"'"'4'"'"') FROM RDB$DATABASE;' \
     'MOD MOD MOD|1 0 1'
dpin '6 MOD(text) describes INT64' 'SELECT MOD('"'"'7'"'"', 2) FROM RDB$DATABASE;' \
     '01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8| : name: MOD alias: MOD'
pin  '6 MOD of a non-numeric text' 'SELECT MOD('"'"'x'"'"', 2) FROM RDB$DATABASE;' \
     'MOD|Statement failed, SQLSTATE = 22018|conversion error from string "x"'
pin  '6 ASCII_VAL of a number and a date reads the text' 'SELECT ASCII_VAL(1), ASCII_VAL(12.5), ASCII_VAL(DATE '"'"'2024-01-01'"'"'), ASCII_VAL(-5) FROM RDB$DATABASE;' \
     'ASCII_VAL ASCII_VAL ASCII_VAL ASCII_VAL|49 49 50 45'
pin  '6 ASCII_VAL of a column number' 'SELECT ID, ASCII_VAL(NM), ASCII_VAL(N) FROM T ORDER BY ID;' \
     'ID ASCII_VAL ASCII_VAL|1 49 55|2 <null> 56|3 51 57|4 50 49|5 48 49'
dpin '6 ASCII_VAL(number) describes SHORT' 'SELECT ASCII_VAL(1) FROM RDB$DATABASE;' \
     '01: sqltype: 500 SHORT scale: 0 subtype: 0 len: 2| : name: ASCII_VAL alias: ASCII_VAL'
pin  '6 DATEADD over a NULL operand is NULL' 'SELECT DATEADD(DAY, 1, NULL) FROM RDB$DATABASE;' \
     'DATEADD|<null>'
dpin '6 ... described CHAR(1) NONE' 'SELECT DATEADD(DAY, 1, NULL) FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: DATEADD alias: DATEADD'
pin  'CONTROL 6 DATEADD with a NULL amount' 'SELECT DATEADD(DAY, NULL, DATE '"'"'2024-01-01'"'"'), DATEADD(NULL DAY TO DATE '"'"'2024-01-01'"'"') FROM RDB$DATABASE;' \
     'DATEADD DATEADD|<null> <null>'
dpin '6 CONTROL ... described DATE' 'SELECT DATEADD(DAY, NULL, DATE '"'"'2024-01-01'"'"') FROM RDB$DATABASE;' \
     '01: sqltype: 570 SQL DATE Nullable scale: 0 subtype: 0 len: 4| : name: DATEADD alias: DATEADD'
pin  '6 DATEADD over a text operand raises per row' 'SELECT DATEADD(DAY, 1, '"'"'2024-01-01'"'"') FROM RDB$DATABASE;' \
     'DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Invalid data type in addition of part to DATE/TIME/TIMESTAMP in DATEADD'
dpin '6 ... after describing the operand'"'"'s text' 'SELECT DATEADD(DAY, 1, '"'"'2024-01-01'"'"') FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 10 charset: 0 SYSTEM.NONE| : name: DATEADD alias: DATEADD|Statement failed, SQLSTATE = 42000'
pin  'CONTROL 6 DATEADD amount coercions (the fnargs round)' 'SELECT DATEADD(DAY, 2.5e0, DATE '"'"'2024-01-01'"'"'), DATEADD(DAY, '"'"'5'"'"', DATE '"'"'2024-01-01'"'"'), ABS('"'"'-5'"'"') FROM RDB$DATABASE;' \
     'DATEADD DATEADD ABS|2024-01-04 2024-01-06 5.000000000000000'
echo '--- 7. HEX / BASE64 encode and decode'
pin  '7 the four codecs over a literal' 'SELECT HEX_ENCODE('"'"'abc'"'"'), BASE64_ENCODE('"'"'abc'"'"'), HEX_DECODE('"'"'616263'"'"'), BASE64_DECODE('"'"'YWJj'"'"') FROM RDB$DATABASE;' \
     'HEX_ENCODE BASE64_ENCODE HEX_DECODE BASE64_DECODE|616263 YWJj 616263 616263'
dpin '7 describes: VARYING ASCII 6 / 4, OCTETS 3 / 3' 'SELECT HEX_ENCODE('"'"'abc'"'"'), BASE64_ENCODE('"'"'abc'"'"'), HEX_DECODE('"'"'616263'"'"'), BASE64_DECODE('"'"'YWJj'"'"') FROM RDB$DATABASE;' \
     '01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 6 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE|02: sqltype: 448 VARYING scale: 0 subtype: 0 len: 4 charset: 2 SYSTEM.ASCII| : name: BASE64_ENCODE alias: BASE64_ENCODE|03: sqltype: 448 VARYING scale: 0 subtype: 0 len: 3 charset: 1 SYSTEM.OCTETS| : name: HEX_DECODE alias: HEX_DECODE|04: sqltype: 448 VARYING scale: 0 subtype: 0 len: 3 charset: 1 SYSTEM.OCTETS| : name: BASE64_DECODE alias: BASE64_DECODE'
pin  '7 over columns: a CHAR keeps its padding, UTF8 / WIN1252 their bytes' 'SELECT HEX_ENCODE(C), HEX_ENCODE(U), HEX_ENCODE(W), BASE64_ENCODE(U) FROM T WHERE ID = 1;' \
     'HEX_ENCODE HEX_ENCODE HEX_ENCODE BASE64_ENCODE|6162202020 C3A9 C3A9 w6k='
dpin '7 describes over columns: the operand'"'"'s BYTE length' 'SELECT HEX_ENCODE(C), HEX_ENCODE(U), HEX_ENCODE(W), BASE64_ENCODE(U), HEX_ENCODE(V) FROM T WHERE ID = 1;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 10 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 80 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE|03: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE|04: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 56 charset: 2 SYSTEM.ASCII| : name: BASE64_ENCODE alias: BASE64_ENCODE|05: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 40 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE'
dpin '7 decoder describes over a column: its CHARACTER length' 'SELECT HEX_DECODE(HX), BASE64_DECODE(B64) FROM T WHERE ID = 1;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 10 charset: 1 SYSTEM.OCTETS| : name: HEX_DECODE alias: HEX_DECODE|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 15 charset: 1 SYSTEM.OCTETS| : name: BASE64_DECODE alias: BASE64_DECODE'
pin  '7 per-row decode, errors in delivery order' 'SELECT ID, HEX_DECODE(HX) FROM T ORDER BY ID;' \
     'ID HEX_DECODE|1 616263|Statement failed, SQLSTATE = 22023|Invalid hex digit G at position 2'
pin  '7 per-row base64 decode' 'SELECT ID, BASE64_DECODE(B64) FROM T WHERE ID = 1;' \
     'ID BASE64_DECODE|1 616263'
pin  '7 a base64 value whose length is no multiple of 4' 'SELECT BASE64_DECODE(B64) FROM T WHERE ID = 2;' \
     'BASE64_DECODE|Statement failed, SQLSTATE = 22023|Wrong base64 text length 6, should be multiple of 4'
pin  '7 an empty base64 value' 'SELECT BASE64_DECODE(B64) FROM T WHERE ID = 4;' \
     'BASE64_DECODE|Statement failed, SQLSTATE = 22023|Wrong base64 text length 0, should be multiple of 4'
pin  '7 a lone trailing sextet is TomCrypt'"'"'s invalid packet' 'SELECT BASE64_DECODE('"'"'Y==='"'"') FROM RDB$DATABASE;' \
     'BASE64_DECODE|Statement failed, SQLSTATE = 22023|TomCrypt library error: Invalid input packet.|-Decoding BASE64'
pin  '7 relaxed: a stray character is skipped' 'SELECT BASE64_DECODE('"'"'YW=j'"'"'), BASE64_DECODE('"'"'YW!j'"'"'), BASE64_DECODE('"'"'YQ=='"'"') FROM RDB$DATABASE;' \
     'BASE64_DECODE BASE64_DECODE BASE64_DECODE|6168 6168 61'
pin  '7 a hex digit error names the digit and position' 'SELECT HEX_DECODE('"'"'6G'"'"') FROM RDB$DATABASE;' \
     'HEX_DECODE|Statement failed, SQLSTATE = 22023|Invalid hex digit G at position 2'
pin  '7 lower-case hex digits decode' 'SELECT HEX_DECODE(HX) FROM T WHERE ID = 5;' \
     'HEX_DECODE|0A0B'
pin  '7 HEX_DECODE('"'"'616'"'"') is its prepare length error' 'SELECT HEX_DECODE('"'"'616'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid hex text length 3, should be multiple of 2'
pin  '7 BASE64_DECODE('"'"'YWJ'"'"') likewise' 'SELECT BASE64_DECODE('"'"'YWJ'"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Wrong base64 text length 3, should be multiple of 4'
pin  '7 HEX_DECODE('"'"''"'"') and BASE64_DECODE('"'"''"'"')' 'SELECT HEX_DECODE('"'"''"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid hex text length 0, should be multiple of 2'
pin  '7 ... base64' 'SELECT BASE64_DECODE('"'"''"'"') FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Wrong base64 text length 0, should be multiple of 4'
pin  '7 a CHAR(5) operand'"'"'s odd length fails the prepare' 'SELECT HEX_DECODE(C) FROM T;' \
     'Statement failed, SQLSTATE = 22023|Invalid hex text length 5, should be multiple of 2'
pin  '7 a number is not a string' 'SELECT HEX_ENCODE(1) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid first parameter datatype - need string or blob'
pin  '7 ... to the decoders either' 'SELECT BASE64_DECODE(12.5) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid first parameter datatype - need string or blob'
pin  '7 a NULL literal: the encoders refuse it' 'SELECT HEX_ENCODE(NULL) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid first parameter datatype - need string or blob'
pin  '7 ... BASE64_ENCODE' 'SELECT BASE64_ENCODE(NULL) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid first parameter datatype - need string or blob'
pin  '7 ... the decoders read CHAR(1)' 'SELECT HEX_DECODE(NULL) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Invalid hex text length 1, should be multiple of 2'
pin  '7 ... BASE64_DECODE' 'SELECT BASE64_DECODE(NULL) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 22023|Wrong base64 text length 1, should be multiple of 4'
pin  '7 a typed NULL answers NULL' 'SELECT HEX_ENCODE(CAST(NULL AS VARCHAR(3))), BASE64_DECODE(CAST(NULL AS VARCHAR(8))) FROM RDB$DATABASE;' \
     'HEX_ENCODE BASE64_DECODE|<null> <null>'
pin  '7 empty values' 'SELECT HEX_ENCODE('"'"''"'"') || '"'"'|'"'"', BASE64_ENCODE('"'"''"'"') || '"'"'|'"'"' FROM RDB$DATABASE;' \
     'CONCATENATION CONCATENATION|| |'
pin  '7 binary operands' 'SELECT HEX_ENCODE(x'"'"'00FF'"'"'), BASE64_ENCODE(x'"'"'FFFE'"'"'), HEX_ENCODE(HEX_DECODE('"'"'0a0B'"'"')) FROM RDB$DATABASE;' \
     'HEX_ENCODE BASE64_ENCODE HEX_ENCODE|00FF //4= 0A0B'
pin  '7 round trips' 'SELECT ID, BASE64_DECODE(BASE64_ENCODE(V)) = V, HEX_DECODE(HEX_ENCODE(U)) FROM T WHERE ID IN (1, 2) ORDER BY ID;' \
     'ID BOOL HEX_DECODE|1 <true> C3A9|2 <true> CF89'
pin  '7 in a WHERE' 'SELECT ID FROM T WHERE HEX_ENCODE(V) = '"'"'62'"'"';' \
     'ID|1'
pinu '7 HEX_ENCODE of a UTF8 literal' 'SELECT HEX_ENCODE('"'"'é'"'"'), BASE64_ENCODE('"'"'ωa'"'"') FROM RDB$DATABASE;' \
     'HEX_ENCODE BASE64_ENCODE|C3A9 z4lh'
pinu '7 HEX_ENCODE over columns under UTF8' 'SELECT HEX_ENCODE(C), HEX_ENCODE(W) FROM T WHERE ID = 1;' \
     'HEX_ENCODE HEX_ENCODE|6162202020 C3A9'
dpinu '7 describes under UTF8: a literal counts 4 bytes a character' 'SELECT HEX_ENCODE('"'"'é'"'"'), BASE64_ENCODE('"'"'é'"'"'), HEX_DECODE('"'"'6162'"'"'), HEX_ENCODE(W) FROM T WHERE ID = 1;' \
     '01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 32 charset: 4 SYSTEM.UTF8| : name: HEX_ENCODE alias: HEX_ENCODE|02: sqltype: 448 VARYING scale: 0 subtype: 0 len: 32 charset: 4 SYSTEM.UTF8| : name: BASE64_ENCODE alias: BASE64_ENCODE|03: sqltype: 448 VARYING scale: 0 subtype: 0 len: 2 charset: 1 SYSTEM.OCTETS| : name: HEX_DECODE alias: HEX_DECODE|04: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 80 charset: 4 SYSTEM.UTF8| : name: HEX_ENCODE alias: HEX_ENCODE'
echo '--- 8. UUID_TO_CHAR / CHAR_TO_UUID'
pin  '8 the round trip' 'SELECT UUID_TO_CHAR(CHAR_TO_UUID('"'"'A0BF4E45-3029-2A44-D493-4998C9B439A3'"'"')) FROM RDB$DATABASE;' \
     'UUID_TO_CHAR|A0BF4E45-3029-2A44-D493-4998C9B439A3'
pin  '8 UUID_TO_CHAR of 16 bytes' 'SELECT UUID_TO_CHAR(x'"'"'A0BF4E4530292A44D4934998C9B439A3'"'"'), CHAR_TO_UUID('"'"'a0bf4e45-3029-2a44-d493-4998c9b439a3'"'"') FROM RDB$DATABASE;' \
     'UUID_TO_CHAR CHAR_TO_UUID|A0BF4E45-3029-2A44-D493-4998C9B439A3 A0BF4E4530292A44D4934998C9B439A3'
dpin '8 describe: CHAR(36) ASCII, CHAR(16) OCTETS, a NULL operand CHAR(1) NONE' 'SELECT UUID_TO_CHAR(x'"'"'A0BF4E4530292A44D4934998C9B439A3'"'"'), CHAR_TO_UUID('"'"'A0BF4E45-3029-2A44-D493-4998C9B439A3'"'"'), UUID_TO_CHAR(NULL), CHAR_TO_UUID(NULL) FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 36 charset: 2 SYSTEM.ASCII| : name: UUID_TO_CHAR alias: UUID_TO_CHAR|02: sqltype: 452 TEXT scale: 0 subtype: 0 len: 16 charset: 1 SYSTEM.OCTETS| : name: CHAR_TO_UUID alias: CHAR_TO_UUID|03: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: UUID_TO_CHAR alias: UUID_TO_CHAR|04: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: CHAR_TO_UUID alias: CHAR_TO_UUID'
pin  '8 NULLs' 'SELECT UUID_TO_CHAR(NULL), CHAR_TO_UUID(NULL) FROM RDB$DATABASE;' \
     'UUID_TO_CHAR CHAR_TO_UUID|<null> <null>'
pin  '8 trailing blanks past 36 are dropped' 'SELECT CHAR_TO_UUID('"'"'A0BF4E45-3029-2A44-D493-4998C9B439A3   '"'"') FROM RDB$DATABASE;' \
     'CHAR_TO_UUID|A0BF4E4530292A44D4934998C9B439A3'
pin  '8 the wrong length' 'SELECT CHAR_TO_UUID('"'"'xyz'"'"') FROM RDB$DATABASE;' \
     'CHAR_TO_UUID|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Human readable UUID argument for CHAR_TO_UUID must be of exact length 36'
pin  '8 a missing dash' 'SELECT CHAR_TO_UUID('"'"'A0BF4E45x3029-2A44-D493-4998C9B439A3'"'"') FROM RDB$DATABASE;' \
     'CHAR_TO_UUID|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Human readable UUID argument for CHAR_TO_UUID must have "-" at position 9 instead of "x (ASCII 120)"'
pin  '8 a non-hex digit' 'SELECT CHAR_TO_UUID('"'"'G0BF4E45-3029-2A44-D493-4998C9B439A3'"'"') FROM RDB$DATABASE;' \
     'CHAR_TO_UUID|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Human readable UUID argument for CHAR_TO_UUID must have hex digit at position 1 instead of "G (ASCII 71)"'
pin  '8 UUID_TO_CHAR of the wrong size' 'SELECT UUID_TO_CHAR('"'"'abc'"'"') FROM RDB$DATABASE;' \
     'UUID_TO_CHAR|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Binary UUID argument for UUID_TO_CHAR must use 16 bytes'
pin  '8 UUID_TO_CHAR of a number' 'SELECT UUID_TO_CHAR(5) FROM RDB$DATABASE;' \
     'UUID_TO_CHAR|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Binary UUID argument for UUID_TO_CHAR must be of string type'
pin  '8 CHAR_TO_UUID of a number' 'SELECT CHAR_TO_UUID(5) FROM RDB$DATABASE;' \
     'CHAR_TO_UUID|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Human readable UUID argument for CHAR_TO_UUID must be of string type'
pin  '8 in a WHERE' 'SELECT 1 FROM RDB$DATABASE WHERE UUID_TO_CHAR(CHAR_TO_UUID('"'"'A0BF4E45-3029-2A44-D493-4998C9B439A3'"'"')) STARTING WITH '"'"'A0BF'"'"';' \
     'CONSTANT|1'
dpinu '8 describes under UTF8' 'SELECT UUID_TO_CHAR(x'"'"'A0BF4E4530292A44D4934998C9B439A3'"'"'), CHAR_TO_UUID('"'"'A0BF4E45-3029-2A44-D493-4998C9B439A3'"'"'), CRYPT_HASH('"'"'a'"'"' USING SHA1) FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 144 charset: 4 SYSTEM.UTF8| : name: UUID_TO_CHAR alias: UUID_TO_CHAR|02: sqltype: 452 TEXT scale: 0 subtype: 0 len: 16 charset: 1 SYSTEM.OCTETS| : name: CHAR_TO_UUID alias: CHAR_TO_UUID|03: sqltype: 448 VARYING scale: 0 subtype: 0 len: 20 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH'
pinu '8 values under UTF8' 'SELECT UUID_TO_CHAR(x'"'"'A0BF4E4530292A44D4934998C9B439A3'"'"') || '"'"'|'"'"' FROM RDB$DATABASE;' \
     'CONCATENATION|A0BF4E45-3029-2A44-D493-4998C9B439A3|'
echo '--- 9. CRYPT_HASH'
pin  '9 every algorithm over '"'"'abc'"'"'' 'SELECT CRYPT_HASH('"'"'abc'"'"' USING MD5), CRYPT_HASH('"'"'abc'"'"' USING SHA1), CRYPT_HASH('"'"'abc'"'"' USING SHA256) FROM RDB$DATABASE;' \
     'CRYPT_HASH CRYPT_HASH CRYPT_HASH|900150983CD24FB0D6963F7D28E17F72 A9993E364706816ABA3E25717850C26C9CD0D89D BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
pin  '9 SHA512 over '"'"''"'"'' 'SELECT CRYPT_HASH('"'"''"'"' USING SHA512) FROM RDB$DATABASE;' \
     'CRYPT_HASH|CF83E1357EEFB8BDF1542850D66D8007D620E4050B5715DC83F4A921D36CE9CE47D0D13C5D85F2B0FF8318D2877EEC2F63B931BD47417A81A538327AF927DA3E'
pin  '9 the SHA3 family' 'SELECT CRYPT_HASH('"'"'abc'"'"' USING SHA3_224), CRYPT_HASH('"'"'abc'"'"' USING SHA3_256) FROM RDB$DATABASE;' \
     'CRYPT_HASH CRYPT_HASH|E642824C3F8CF24AD09234EE7D3C766FC9A3A5168D0C94AD73B46FDF 3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532'
pin  '9 SHA3_384 / SHA3_512' 'SELECT CRYPT_HASH('"'"'abc'"'"' USING SHA3_384), CRYPT_HASH('"'"'abc'"'"' USING SHA3_512) FROM RDB$DATABASE;' \
     'CRYPT_HASH CRYPT_HASH|EC01498288516FC926459F58E2C6AD8DF9B473CB0FC08C2596DA7CF0E49BE4B298D88CEA927AC7F539F1EDF228376D25 B751850B1A57168A5693CD924B6B096E08F621827444F70D884F5D0240D2712E10E116E9192AF3C91A7EC57647E3934057340B4CF408D5A56592F8274EEC53F0'
dpin '9 describe: VARYING(digest length) OCTETS' 'SELECT CRYPT_HASH('"'"'abc'"'"' USING MD5), CRYPT_HASH('"'"'abc'"'"' USING SHA1), CRYPT_HASH('"'"'abc'"'"' USING SHA512), CRYPT_HASH('"'"'abc'"'"' USING SHA3_224), CRYPT_HASH(NULL USING MD5) FROM RDB$DATABASE;' \
     '01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 16 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH|02: sqltype: 448 VARYING scale: 0 subtype: 0 len: 20 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH|03: sqltype: 448 VARYING scale: 0 subtype: 0 len: 64 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH|04: sqltype: 448 VARYING scale: 0 subtype: 0 len: 28 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH|05: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 16 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH'
pin  '9 a number hashes its text' 'SELECT CRYPT_HASH(5 USING MD5), CRYPT_HASH(1.5 USING SHA1) FROM RDB$DATABASE;' \
     'CRYPT_HASH CRYPT_HASH|E4DA3B7FBBCE2345D7772B0674A318D5 AA8F289EBE6D4DB1B4A1038B8931EC8C2B5399FB'
pin  '9 NULL' 'SELECT CRYPT_HASH(NULL USING SHA256) FROM RDB$DATABASE;' \
     'CRYPT_HASH|<null>'
pin  '9 over columns: the stored bytes' 'SELECT ID, CRYPT_HASH(U USING MD5), CRYPT_HASH(C USING MD5) FROM T WHERE ID IN (1, 2) ORDER BY ID;' \
     'ID CRYPT_HASH CRYPT_HASH|1 66DDCD97CFDEABB2F6FB8A999B4BC76F 10B156A4E4C9529CBDE8C9A58044DA30|2 45BF03A575F6E81359314E906FB2BFF3 16067BDCBD3BC77D330E8E708448DFDB'
pin  '9 a long operand (several blocks)' 'SELECT CRYPT_HASH(LPAD('"'"''"'"', 300, '"'"'x'"'"') USING SHA3_256), CRYPT_HASH(LPAD('"'"''"'"', 300, '"'"'x'"'"') USING SHA512) FROM RDB$DATABASE;' \
     'CRYPT_HASH CRYPT_HASH|34ED36D4D71D1A9A582CCE5A006D6102D173FD867A27BE7B2FE5D854587DDBA2 0DC240AE43B18EEACEF4D7D8D64B945ADE43C989B724D7C7062A8029F3343CAA322B9FBF42D9FF0CDA98F3D7AC5A560CA219B2E73CC041F37052DFA4E84AE624'
pin  '9 an unknown algorithm' 'SELECT CRYPT_HASH('"'"'abc'"'"' USING FOO) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 42000|Invalid HASH algorithm FOO'
pin  '9 CRC32 is HASH'"'"'s, not CRYPT_HASH'"'"'s' 'SELECT CRYPT_HASH('"'"'abc'"'"' USING CRC32) FROM RDB$DATABASE;' \
     'Statement failed, SQLSTATE = 42000|Invalid HASH algorithm CRC32'
pin  '9 in a WHERE' 'SELECT ID FROM T WHERE CRYPT_HASH(V USING MD5) = CRYPT_HASH('"'"'b'"'"' USING MD5);' \
     'ID|1'
pin  'CONTROL 9 HASH is unchanged' 'SELECT HASH('"'"'abc'"'"'), HASH('"'"'abc'"'"' USING CRC32) FROM RDB$DATABASE;' \
     'HASH HASH|26499 -1035918283'
echo '--- 10. OVERLAY'
pin  '10 OVERLAY('"'"'Hello World'"'"' PLACING '"'"'XX'"'"' FROM 3)' 'SELECT OVERLAY('"'"'Hello World'"'"' PLACING '"'"'XX'"'"' FROM 3) FROM RDB$DATABASE;' \
     'OVERLAY|HeXXo World'
dpin '10 describe: VARYING of both widths' 'SELECT OVERLAY('"'"'Hello World'"'"' PLACING '"'"'XX'"'"' FROM 3), OVERLAY(V PLACING '"'"'Q'"'"' FROM 1 FOR 5), OVERLAY(U PLACING '"'"'xy'"'"' FROM 1) FROM T WHERE ID = 1;' \
     '01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 13 charset: 0 SYSTEM.NONE| : name: OVERLAY alias: OVERLAY|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 21 charset: 0 SYSTEM.NONE| : name: OVERLAY alias: OVERLAY|03: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 48 charset: 4 SYSTEM.UTF8| : name: OVERLAY alias: OVERLAY'
pin  '10 FOR 0 inserts' 'SELECT OVERLAY('"'"'Hello'"'"' PLACING '"'"'XX'"'"' FROM 3 FOR 0) FROM RDB$DATABASE;' \
     'OVERLAY|HeXXllo'
pin  '10 FROM past the end appends' 'SELECT OVERLAY('"'"'Hello'"'"' PLACING '"'"'XX'"'"' FROM 9), OVERLAY('"'"'Hello'"'"' PLACING '"'"'XX'"'"' FROM 6) FROM RDB$DATABASE;' \
     'OVERLAY OVERLAY|HelloXX HelloXX'
pin  '10 FOR past the end replaces the rest' 'SELECT OVERLAY('"'"'Hello'"'"' PLACING '"'"'XX'"'"' FROM 2 FOR 99) FROM RDB$DATABASE;' \
     'OVERLAY|HXX'
pin  '10 FROM 0 is the #3 error' 'SELECT OVERLAY('"'"'Hello'"'"' PLACING '"'"'XX'"'"' FROM 0) FROM RDB$DATABASE;' \
     'OVERLAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument #3 for OVERLAY must be positive'
pin  '10 a negative FOR is the #4 error' 'SELECT OVERLAY('"'"'Hello'"'"' PLACING '"'"'XX'"'"' FROM 2 FOR -1) FROM RDB$DATABASE;' \
     'OVERLAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument #4 for OVERLAY must be zero or positive'
pin  '10 text and rounded counts' 'SELECT OVERLAY('"'"'abc'"'"' PLACING '"'"'Z'"'"' FROM '"'"'2'"'"'), OVERLAY('"'"'abc'"'"' PLACING '"'"'Z'"'"' FROM 2.6 FOR 1.4) FROM RDB$DATABASE;' \
     'OVERLAY OVERLAY|aZc abZ'
pin  '10 numbers render to text' 'SELECT OVERLAY(123 PLACING '"'"'Z'"'"' FROM 2), OVERLAY('"'"'abc'"'"' PLACING 9 FROM 2) FROM RDB$DATABASE;' \
     'OVERLAY OVERLAY|1Z3 a9c'
dpin '10 ... at their rendered widths' 'SELECT OVERLAY(123 PLACING '"'"'Z'"'"' FROM 2), OVERLAY('"'"'abc'"'"' PLACING 9 FROM 2) FROM RDB$DATABASE;' \
     '01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 12 charset: 0 SYSTEM.NONE| : name: OVERLAY alias: OVERLAY|02: sqltype: 448 VARYING scale: 0 subtype: 0 len: 14 charset: 0 SYSTEM.NONE| : name: OVERLAY alias: OVERLAY'
pin  '10 NULL anywhere is NULL' 'SELECT OVERLAY(NULL PLACING '"'"'a'"'"' FROM 1), OVERLAY('"'"'a'"'"' PLACING NULL FROM 1), OVERLAY('"'"'a'"'"' PLACING '"'"'b'"'"' FROM NULL) FROM RDB$DATABASE;' \
     'OVERLAY OVERLAY OVERLAY|<null> <null> <null>'
dpin '10 a NULL literal describes CHAR(1) NONE' 'SELECT OVERLAY(NULL PLACING '"'"'a'"'"' FROM 1) FROM RDB$DATABASE;' \
     '01: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: OVERLAY alias: OVERLAY'
pin  '10 over columns: a CHAR keeps its padding, UTF8 counts characters' 'SELECT ID, OVERLAY(C PLACING '"'"'Z'"'"' FROM 2), OVERLAY(U PLACING '"'"'xy'"'"' FROM 1 FOR 1) FROM T WHERE ID IN (1, 2, 4) ORDER BY ID;' \
     'ID OVERLAY OVERLAY|1 aZ xy|2 QZ xy|4 xZz xyb'
pin  '10 a UTF8 placing into a literal' 'SELECT OVERLAY('"'"'abc'"'"' PLACING U FROM 2) FROM T WHERE ID = 1;' \
     'OVERLAY|aéc'
pin  '10 in a WHERE' 'SELECT ID FROM T WHERE OVERLAY(V PLACING '"'"'z'"'"' FROM 1) = '"'"'z'"'"' ORDER BY ID;' \
     'ID|1|2|3|5'
dpinu '10 describes under UTF8' 'SELECT OVERLAY(V PLACING '"'"'Q'"'"' FROM 1), OVERLAY(U PLACING '"'"'xy'"'"' FROM 1), OVERLAY(W PLACING '"'"'ab'"'"' FROM 1) FROM T WHERE ID = 1;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 84 charset: 4 SYSTEM.UTF8| : name: OVERLAY alias: OVERLAY|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 48 charset: 4 SYSTEM.UTF8| : name: OVERLAY alias: OVERLAY|03: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 48 charset: 4 SYSTEM.UTF8| : name: OVERLAY alias: OVERLAY'
rec  '10 RECORDED a non-ASCII literal placed into another set'"'"'s column (the engine transliterates it)' 'SELECT OVERLAY(W PLACING '"'"'é'"'"' FROM 1) FROM T WHERE ID = 4;' \
     'OVERLAY|é' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo '--- 11. LISTAGG is LIST, and WITHIN GROUP orders it'
pinb '11 LISTAGG ... WITHIN GROUP (ORDER BY V)' 'SELECT LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY V) FROM T;' \
     'LIST|<blob>|LIST:|a,b,c,d'
pinb '11 LISTAGG without WITHIN GROUP: row order' 'SELECT LISTAGG(V) FROM T;' \
     'LIST|<blob>|LIST:|b,a,c,d'
dpin '11 describe: a LIST blob' 'SELECT LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY V) FROM T;' \
     '01: sqltype: 520 BLOB Nullable scale: 0 subtype: 1 len: 8 charset: 0 SYSTEM.NONE| : name: LIST alias: LIST'
pinb '11 DESC' 'SELECT LISTAGG(V, '"'"'-'"'"') WITHIN GROUP (ORDER BY V DESC) FROM T;' \
     'LIST|<blob>|LIST:|d-c-b-a'
pinb '11 a NULL key goes first ascending' 'SELECT LISTAGG(V, '"'"';'"'"') WITHIN GROUP (ORDER BY K) FROM T;' \
     'LIST|<blob>|LIST:|d;a;c;b'
pinb '11 ... last descending' 'SELECT LISTAGG(V, '"'"';'"'"') WITHIN GROUP (ORDER BY K DESC) FROM T;' \
     'LIST|<blob>|LIST:|b;c;a;d'
pinb '11 NULLS LAST / NULLS FIRST' 'SELECT LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY K NULLS LAST), LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY K DESC NULLS FIRST) FROM T;' \
     'LIST LIST|<blob> <blob>|LIST:|a,c,b,d|LIST:|d,b,c,a'
pinb '11 per group' 'SELECT G, LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY ID DESC) FROM T GROUP BY G ORDER BY G;' \
     'G LIST|1 <blob>|LIST:|d,a,b|2 <blob>|LIST:|c'
pinb '11 DISTINCT' 'SELECT LISTAGG(DISTINCT G, '"'"','"'"') FROM T;' \
     'LIST|<blob>|LIST:|1,2'
pinb '11 two keys, ties in row order' 'SELECT LISTAGG(ID, '"'"','"'"') WITHIN GROUP (ORDER BY G, K DESC) FROM T;' \
     'LIST|<blob>|LIST:|1,2,5,3,4'
pinb '11 an expression key' 'SELECT LISTAGG(ID) WITHIN GROUP (ORDER BY MOD(ID, 3), ID) FROM T;' \
     'LIST|<blob>|LIST:|3,1,4,2,5'
pinb '11 mixed case, in a WHERE-filtered set' 'SELECT ListAgg (V) FROM T WHERE ID = 1;' \
     'LIST|<blob>|LIST:|b'
rec  '11 RECORDED a non-ASCII separator under a NONE attachment joins its UTF-8 spelling - LIST'"'"'s own fold (master'"'"'s LIST(V, '"'"'é'"'"') the same)' 'SELECT LISTAGG(V, '"'"'é'"'"') WITHIN GROUP (ORDER BY ID DESC) FROM T;' \
     'LIST|<blob>|LIST:|décéaéb' 'LIST|<blob>|LIST:|dÃ©cÃ©aÃ©b' sessb
rec  '11 RECORDED a key in a single-byte page'"'"'s order is not modelled' 'SELECT LISTAGG(ID) WITHIN GROUP (ORDER BY W) FROM T;' \
     'LIST|0:1|LIST:|3,4,2,5,1' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin  'CONTROL 11 the word inside a string is left alone' 'SELECT '"'"'listagg('"'"' || V || '"'"')'"'"' FROM T WHERE ID = 1;' \
     'CONCATENATION|listagg(b)'
pin  'CONTROL 11 LIST is unchanged' 'SELECT COUNT(*) FROM T WHERE ID < 3;' \
     'COUNT|2'
echo '--- 12. A scaled literal past INT64 is an INT128 NUMERIC (past INT128 a DECFLOAT)'
pin  '12 CAST(<33 digits>.123 AS NUMERIC(38,3))' 'SELECT CAST(123456789012345678901234567890.123 AS NUMERIC(38,3)) FROM RDB$DATABASE;' \
     'CAST|123456789012345678901234567890.123'
pin  '12 CAST(<19 digits>.5 AS DECFLOAT(34))' 'SELECT CAST(1234567890123456789.5 AS DECFLOAT(34)) FROM RDB$DATABASE;' \
     'CAST|1234567890123456789.5'
pin  '12 rounding into a narrower scale' 'SELECT CAST(1234567890123456789.55 AS NUMERIC(38,1)) FROM RDB$DATABASE;' \
     'CAST|1234567890123456789.6'
pin  '12 the bare literal is a CONSTANT' 'SELECT 123456789012345678901234567890.123 FROM RDB$DATABASE;' \
     'CONSTANT|123456789012345678901234567890.123'
dpin '12 described INT128 at its scale, SUBTYPE 0' 'SELECT 123456789012345678901234567890.123, -1234567890123456789.5 AS A, 1234567890123456789.5 + 1 AS B FROM RDB$DATABASE;' \
     '01: sqltype: 32752 INT128 scale: -3 subtype: 0 len: 16| : name: CONSTANT alias: CONSTANT|02: sqltype: 32752 INT128 scale: -1 subtype: 0 len: 16| : name: CONSTANT alias: A|03: sqltype: 32752 INT128 scale: -1 subtype: 0 len: 16| : name: ADD alias: B'
pin  '12 negated and in arithmetic' 'SELECT -1234567890123456789.5 AS A, 1234567890123456789.5 + 1 AS B FROM RDB$DATABASE;' \
     'A B|-1234567890123456789.5 1234567890123456790.5'
pin  '12 thirty-nine digits' 'SELECT CAST(12345678901234567890123456789012345678.9 AS NUMERIC(38,1)) FROM RDB$DATABASE;' \
     'CAST|12345678901234567890123456789012345678.9'
pin  '12 past INT128 it is DECFLOAT(34)' 'SELECT 99999999999999999999999999999999999999.9 FROM RDB$DATABASE;' \
     'CONSTANT|1.000000000000000000000000000000000E+38'
pin  '12 twenty fraction digits' 'SELECT 1.00000000000000000001 FROM RDB$DATABASE;' \
     'CONSTANT|1.00000000000000000001'
pin  '12 in a WHERE' 'SELECT ID FROM T WHERE NM < 1234567890123456789.5 AND ID < 3 ORDER BY ID;' \
     'ID|1'
pin  '12 in a WHERE, past INT128' 'SELECT 1 FROM RDB$DATABASE WHERE 99999999999999999999999999999999999999.9 > 1;' \
     'CONSTANT|1'
pin  '12 as text' 'SELECT CAST(1234567890123456789.5 AS VARCHAR(40)) FROM RDB$DATABASE;' \
     'CAST|1234567890123456789.5'
pin  'CONTROL 12 a literal within INT64 is unchanged' 'SELECT CAST(12345.678 AS NUMERIC(18,3)), 123456789012345.67 FROM RDB$DATABASE;' \
     'CAST CONSTANT|12345.678 123456789012345.67'
echo '--- 14. The review of the built-ins: LISTAGG ties, MAXVALUE'"'"'s refusals and zone kinds, the double conversions, blob operands'
pinb '14 LISTAGG ties on the key go by the aggregated value (the sort record)' 'SELECT LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY G) FROM T;' \
     'LIST|<blob>|LIST:|a,b,d,c'
pinb '14 ... whatever the key direction' 'SELECT LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY G DESC) FROM T;' \
     'LIST|<blob>|LIST:|c,a,b,d'
pinb '14 ... an INTEGER value by its unsigned native word' 'SELECT LISTAGG(-ID, '"'"','"'"') WITHIN GROUP (ORDER BY G) FROM T;' \
     'LIST|<blob>|LIST:|-5,-2,-1,-4,-3'
pinb '14 ... a VARCHAR value by its word, second byte first' 'SELECT LISTAGG(ID || V, '"'"','"'"') WITHIN GROUP (ORDER BY G) FROM T;' \
     'LIST|<blob>|LIST:|2a,1b,5d,3c'
pinb '14 ... a constant key ties every row' 'SELECT LISTAGG(V, '"'"','"'"') WITHIN GROUP (ORDER BY '"'"'k'"'"') FROM T;' \
     'LIST|<blob>|LIST:|a,b,c,d'
pinb '14 ... per group' 'SELECT G, LISTAGG(-ID, '"'"','"'"') WITHIN GROUP (ORDER BY 1 DESC) FROM T GROUP BY G ORDER BY G;' \
     'G LIST|1 <blob>|LIST:|-5,-2,-1|2 <blob>|LIST:|-4,-3'
rec  '14 RECORDED MAXVALUE of a number beside two texts is not transitive: refused' 'SELECT MAXVALUE('"'"'9'"'"', '"'"'10'"'"', 9.5, 1) FROM RDB$DATABASE;' \
     'MAXVALUE|9.5' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
rec  '14 RECORDED ... LEAST alike' 'SELECT LEAST('"'"'10'"'"', '"'"'9'"'"', 9.5, 100) FROM RDB$DATABASE;' \
     'LEAST|9.5' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin  'CONTROL 14 two texts alone, or one beside numbers, answer' 'SELECT MAXVALUE('"'"'9'"'"', '"'"'10'"'"'), MAXVALUE(1, 2, '"'"'3'"'"'), MINVALUE('"'"'9'"'"', 10, 11) FROM RDB$DATABASE;' \
     'MAXVALUE MAXVALUE MINVALUE|9 3 9'
pin  '14 a zoned TIMESTAMP beside a zone-less one is one kind' 'SELECT MAXVALUE(CURRENT_TIMESTAMP, TIMESTAMP '"'"'2000-01-01 00:00'"'"') > TIMESTAMP '"'"'2001-01-01 00:00'"'"' FROM RDB$DATABASE;' \
     'BOOL|<true>'
pin  '14 ... the zone-less one read in the session zone' 'SELECT MAXVALUE(TS, TIMESTAMP '"'"'1999-01-01 00:00 +00:00'"'"') = TS, MINVALUE(TIMESTAMP '"'"'1999-01-01 00:00 +00:00'"'"', TS) = TIMESTAMP '"'"'1999-01-01 00:00 +00:00'"'"' FROM T WHERE ID = 1;' \
     'BOOL BOOL|<true> <true>'
dpin '14 ... describes the zoned type, TIME alike' 'SELECT MAXVALUE(TS, TIMESTAMP '"'"'1999-01-01 00:00 +00:00'"'"'), MINVALUE(TIME '"'"'10:00'"'"', TIME '"'"'10:00 +02:00'"'"') FROM T WHERE ID = 1;' \
     '01: sqltype: 32754 TIMESTAMP WITH TIME ZONE Nullable scale: 0 subtype: 0 len: 12| : name: MAXVALUE alias: MAXVALUE|02: sqltype: 32756 TIME WITH TIME ZONE scale: 0 subtype: 0 len: 8| : name: MINVALUE alias: MINVALUE'
pin  'CONTROL 14 a DATE beside a zoned TIMESTAMP is still HY004' 'SELECT MAXVALUE(D, CURRENT_TIMESTAMP) FROM T;' \
     'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression MAXVALUE'
rec  '14 RECORDED two real character sets (the engine transliterates, and raises): refused' 'SELECT ID, MAXVALUE(U, W) FROM T ORDER BY ID;' \
     'ID MAXVALUE|1 é|Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin  'CONTROL 14 eight nested calls answer (inside the budget)' 'SELECT MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(ID, 0), 1), 2), 3), 4), 5), 6), 7) FROM T WHERE ID = 1;' \
     'MAXVALUE|7'
rec  '14 RECORDED twelve nested calls are past the lowering budget: refused at once' 'SELECT MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(MAXVALUE(ID, 0), 1), 2), 3), 4), 5), 6), 7), 8), 9), 10), 11) FROM T WHERE ID = 1;' \
     'MAXVALUE|11' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin  '14 SIN of a DECFLOAT past the double'"'"'s range: the conversion'"'"'s 22003' 'SELECT SIN(CAST('"'"'1e400'"'"' AS DECFLOAT(34))) FROM RDB$DATABASE;' \
     'SIN|Statement failed, SQLSTATE = 22003|Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
pin  '14 ATAN of a DECFLOAT past the double'"'"'s range: the conversion'"'"'s 22003' 'SELECT ATAN(CAST('"'"'1e400'"'"' AS DECFLOAT(34))) FROM RDB$DATABASE;' \
     'ATAN|Statement failed, SQLSTATE = 22003|Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
pin  '14 ATAN2 of a DECFLOAT past the double'"'"'s range: the conversion'"'"'s 22003' 'SELECT ATAN2(CAST('"'"'1e400'"'"' AS DECFLOAT(34)), 1) FROM RDB$DATABASE;' \
     'ATAN2|Statement failed, SQLSTATE = 22003|Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
pin  '14 ASINH of a DECFLOAT past the double'"'"'s range: the conversion'"'"'s 22003' 'SELECT ASINH(CAST('"'"'1e400'"'"' AS DECFLOAT(34))) FROM RDB$DATABASE;' \
     'ASINH|Statement failed, SQLSTATE = 22003|Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
pin  '14 TANH of the negative' 'SELECT TANH(CAST('"'"'-1e400'"'"' AS DECFLOAT(34))) FROM RDB$DATABASE;' \
     'TANH|Statement failed, SQLSTATE = 22003|Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
pin  '14 the CAST to DOUBLE PRECISION alike' 'SELECT CAST(CAST('"'"'1e400'"'"' AS DECFLOAT(34)) AS DOUBLE PRECISION) FROM RDB$DATABASE;' \
     'CAST|Statement failed, SQLSTATE = 22003|Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
pin  'CONTROL 14 one below the range is 0' 'SELECT SIN(CAST('"'"'1e-400'"'"' AS DECFLOAT(34))), CAST(CAST('"'"'1e-400'"'"' AS DECFLOAT(34)) AS DOUBLE PRECISION) FROM RDB$DATABASE;' \
     'SIN CAST|0.000000000000000 0.000000000000000'
pin  '14 SIGN of a text whose scale is past the double: 22003' 'SELECT SIGN('"'"'-1.5e-400'"'"') FROM RDB$DATABASE;' \
     'SIGN|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin  '14 ... overflowing it too' 'SELECT SIGN('"'"'1e400'"'"') FROM RDB$DATABASE;' \
     'SIGN|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin  '14 ... a zero spelled past it too' 'SELECT SQRT('"'"'0e-400'"'"') FROM RDB$DATABASE;' \
     'SQRT|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin  '14 ... the CAST: a scale of 309' 'SELECT CAST('"'"'2.3e-308'"'"' AS DOUBLE PRECISION) FROM RDB$DATABASE;' \
     'CAST|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin  'CONTROL 14 inside the range' 'SELECT SIGN('"'"'1e308'"'"'), SIGN('"'"'-2.5e-300'"'"'), SQRT('"'"'4e-306'"'"') FROM RDB$DATABASE;' \
     'SIGN SIGN SQRT|1 -1 2.000000000000000e-153'
dpin '14 CRYPT_HASH over a BLOB is VARYING OCTETS' 'SELECT CRYPT_HASH(BL USING MD5), CRYPT_HASH(BL USING SHA256) FROM TB WHERE ID = 1;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 16 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 32 charset: 1 SYSTEM.OCTETS| : name: CRYPT_HASH alias: CRYPT_HASH'
pin  '14 ... its digest' 'SELECT CRYPT_HASH(BL USING MD5) FROM TB WHERE ID = 1;' \
     'CRYPT_HASH|CD00020814BADF934F0912177F78751C'
pin  '14 ... a blob-typed expression, a NULL blob' 'SELECT ID, CRYPT_HASH('"'"'x'"'"' || BL USING SHA1) FROM TB ORDER BY ID;' \
     'ID CRYPT_HASH|1 2534DD483F9D203D87F6924ADCE0A197EF9430AC|2 <null>'
dpin '14 HEX_ENCODE over it is VARYING ASCII' 'SELECT HEX_ENCODE(CRYPT_HASH(BU USING SHA256)) FROM TB WHERE ID = 1;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 64 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE'
pin  '14 ... the UTF8 blob'"'"'s bytes' 'SELECT HEX_ENCODE(CRYPT_HASH(BU USING SHA256)), CRYPT_HASH(BB USING SHA1) FROM TB WHERE ID = 1;' \
     'HEX_ENCODE CRYPT_HASH|805C58E80D5A6F66D9BED65CFB771031235943EF48FBE5C18B823DF952DA92C4 A9993E364706816ABA3E25717850C26C9CD0D89D'
dpin '14 UNICODE_VAL over a BLOB is INTEGER' 'SELECT UNICODE_VAL(BL) FROM TB WHERE ID = 1;' \
     '01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: UNICODE_VAL alias: UNICODE_VAL'
pin  '14 ... the first code point' 'SELECT UNICODE_VAL(BL), UNICODE_VAL(BU), UNICODE_VAL(CAST('"'"'é'"'"' AS BLOB SUB_TYPE TEXT CHARACTER SET UTF8)) FROM TB WHERE ID = 1;' \
     'UNICODE_VAL UNICODE_VAL UNICODE_VAL|98 233 233'
pin  '14 a CAST of a literal to a UTF8 text blob is its characters' 'SELECT CHAR_LENGTH(CAST('"'"'é'"'"' AS BLOB SUB_TYPE TEXT CHARACTER SET UTF8)) FROM RDB$DATABASE;' \
     'CHAR_LENGTH|1'
pin  '14 UUID_TO_CHAR of a blob: must be of string type' 'SELECT UUID_TO_CHAR(CAST(RPAD('"'"''"'"', 16, '"'"'a'"'"') AS BLOB SUB_TYPE BINARY)) FROM RDB$DATABASE;' \
     'UUID_TO_CHAR|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Binary UUID argument for UUID_TO_CHAR must be of string type'
pin  '14 CHAR_TO_UUID of a blob alike' 'SELECT CHAR_TO_UUID(CAST('"'"'A0BF4E45-3029-2A44-D493-4998C9B439A3'"'"' AS BLOB SUB_TYPE TEXT)) FROM RDB$DATABASE;' \
     'CHAR_TO_UUID|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Human readable UUID argument for CHAR_TO_UUID must be of string type'
pin  'CONTROL 14 ... a NULL blob answers NULL' 'SELECT UUID_TO_CHAR(BB), CHAR_TO_UUID(BL) FROM TB WHERE ID = 2;' \
     'UUID_TO_CHAR CHAR_TO_UUID|<null> <null>'
dpin '14 SIGN / MOD / ACOSH / ASCII_CHAR / UNICODE_CHAR over a BLOB describe their own types' 'SELECT SIGN(BL), MOD(BL, 2), MOD(7, BL), ACOSH(BL), ASCII_CHAR(BL), UNICODE_CHAR(BL), ABS(BL) FROM TB WHERE ID = 1;' \
     '01: sqltype: 500 SHORT Nullable scale: 0 subtype: 0 len: 2| : name: SIGN alias: SIGN|02: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8| : name: MOD alias: MOD|03: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: MOD alias: MOD|04: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8| : name: ACOSH alias: ACOSH|05: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE| : name: ASCII_CHAR alias: ASCII_CHAR|06: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 4 charset: 4 SYSTEM.UTF8| : name: UNICODE_CHAR alias: UNICODE_CHAR|07: sqltype: 480 DOUBLE Nullable scale: 0 subtype: 0 len: 8| : name: ABS alias: ABS|Statement failed, SQLSTATE = 22018'
pin  '14 SIGN(BL): conversion error from string "BLOB"' 'SELECT SIGN(BL) FROM TB WHERE ID = 1;' \
     'SIGN|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 MOD(BL, 2): conversion error from string "BLOB"' 'SELECT MOD(BL, 2) FROM TB WHERE ID = 1;' \
     'MOD|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 MOD(7, BL): conversion error from string "BLOB"' 'SELECT MOD(7, BL) FROM TB WHERE ID = 1;' \
     'MOD|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 ACOSH(BL): conversion error from string "BLOB"' 'SELECT ACOSH(BL) FROM TB WHERE ID = 1;' \
     'ACOSH|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 ASCII_CHAR(BL): conversion error from string "BLOB"' 'SELECT ASCII_CHAR(BL) FROM TB WHERE ID = 1;' \
     'ASCII_CHAR|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 UNICODE_CHAR(BL): conversion error from string "BLOB"' 'SELECT UNICODE_CHAR(BL) FROM TB WHERE ID = 1;' \
     'UNICODE_CHAR|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 TRUNC(BL): conversion error from string "BLOB"' 'SELECT TRUNC(BL) FROM TB WHERE ID = 1;' \
     'TRUNC|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '14 ... a blob literal too - its content is never read' 'SELECT SIGN(CAST('"'"'5'"'"' AS BLOB SUB_TYPE TEXT)) FROM RDB$DATABASE;' \
     'SIGN|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  'CONTROL 14 ... a NULL blob operand answers NULL' 'SELECT SIGN(BL), MOD(BL, 2) FROM TB WHERE ID = 2;' \
     'SIGN MOD|<null> <null>'
pin  'CONTROL 14 a CAST of the blob reads its content' 'SELECT CAST(BL AS INTEGER) FROM TB WHERE ID = 1;' \
     'CAST|Statement failed, SQLSTATE = 22018|conversion error from string "blobv"'

echo '--- 15. The review of the merged round: a double literal in a DECFLOAT item, the codecs over a blob, a DECFLOAT(16) NaN, the blob move'"'"'s limit'
pin  '15 MAXVALUE / MINVALUE of a double literal beside a DECFLOAT(34): the literal is its text' 'SELECT MAXVALUE(0.1e0, CAST(0.1 AS DECFLOAT(34))), MINVALUE(0.1e0, CAST(0.1 AS DECFLOAT(34))), MAXVALUE(CAST(0.1 AS DECFLOAT(34)), 0.1e0) FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE MAXVALUE|0.1 0.1 0.1'
pin  '15 ... a larger literal, a DECFLOAT(16)' 'SELECT MAXVALUE(0.3e0, CAST(0.1 AS DECFLOAT(34))), MAXVALUE(0.1e0, CAST(0.1 AS DECFLOAT(16))) FROM RDB$DATABASE;' \
     'MAXVALUE MAXVALUE|0.3 0.1'
pin  '15 ... the literal compares as the decimal too' 'SELECT MAXVALUE(0.1e0, CAST(0.10000000000000001 AS DECFLOAT(34))), MINVALUE(CAST(0.10000000000000001 AS DECFLOAT(34)), 0.1e0) FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE|0.10000000000000001 0.1'
pin  '15 COALESCE / CASE / IIF / DECODE: every double literal of a DECFLOAT item' 'SELECT COALESCE(0.1e0, D34), COALESCE(0.1e0, DF), IIF(ID = 1, 0.1e0, D34), DECODE(ID, 1, 0.1e0, D34) FROM T WHERE ID = 1;' \
     'COALESCE COALESCE CASE DECODE|0.1 0.1 0.1 0.1'
pin  '15 ... read from its spelling' 'SELECT COALESCE(1.0e-1, D34), COALESCE(1.50e0, DF) FROM T WHERE ID = 1;' \
     'COALESCE COALESCE|0.10 1.50'
pin  '15 ... an arithmetic over them, a negation' 'SELECT COALESCE(1e0/3, D34), COALESCE(0.1e0 + 0.2e0, D34), -COALESCE(0.1e0, D34), COALESCE(0.1e0, D34) + 0 FROM T WHERE ID = 1;' \
     'COALESCE COALESCE ADD|0.3333333333333333333333333333333333 0.3 -0.1 0.1'
pin  '15 ... a condition'"'"'s literal' 'SELECT CASE WHEN 0.1e0 < CAST(0.10000000000000001 AS DECFLOAT(34)) THEN D34 ELSE D34 + 1 END FROM T WHERE ID = 1;' \
     'CASE|7.5'
pin  '15 ... through a derived table' 'SELECT * FROM (SELECT COALESCE(0.1e0, D34) C FROM T WHERE ID = 1);' \
     'C|0.1'
pin  'CONTROL 15 no DECFLOAT item, a UNION branch, an aggregate: the runtime double' 'SELECT COALESCE(0.1e0, D34) || '"'"''"'"', IIF(0.1e0 < CAST(0.10000000000000001 AS DECFLOAT(34)), '"'"'T'"'"', '"'"'F'"'"') FROM T WHERE ID = 1 UNION ALL SELECT CAST(MAX(COALESCE(0.1e0, D34)) AS VARCHAR(40)), '"'"'x'"'"' FROM T;' \
     '0.10000000000000001 F|0.10000000000000001 x'
dpin '15 HEX_DECODE / BASE64_DECODE over a text blob describe BLOB SUB_TYPE BINARY' 'SELECT HEX_DECODE(BT), BASE64_DECODE(BU) FROM TC WHERE ID = 1;' \
     '01: sqltype: 520 BLOB Nullable scale: 0 subtype: 0 len: 8| : name: HEX_DECODE alias: HEX_DECODE|02: sqltype: 520 BLOB Nullable scale: 0 subtype: 0 len: 8| : name: BASE64_DECODE alias: BASE64_DECODE'
dpin '15 HEX_ENCODE / BASE64_ENCODE over a binary blob describe a text blob in ASCII' 'SELECT HEX_ENCODE(BN), BASE64_ENCODE(BN), HEX_ENCODE(BN) || '"'"''"'"', HEX_ENCODE(BT) FROM TC WHERE ID = 1;' \
     '01: sqltype: 520 BLOB Nullable scale: 0 subtype: 1 len: 8 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE|02: sqltype: 520 BLOB Nullable scale: 0 subtype: 1 len: 8 charset: 2 SYSTEM.ASCII| : name: BASE64_ENCODE alias: BASE64_ENCODE|03: sqltype: 520 BLOB Nullable scale: 0 subtype: 1 len: 8 charset: 2 SYSTEM.ASCII| : name: CONCATENATION alias: CONCATENATION|04: sqltype: 520 BLOB Nullable scale: 0 subtype: 1 len: 8 charset: 2 SYSTEM.ASCII| : name: HEX_ENCODE alias: HEX_ENCODE'
pinb '15 ... their values' 'SELECT ID, HEX_ENCODE(BN), BASE64_ENCODE(BN), CAST(HEX_DECODE(BT) AS VARCHAR(10)), OCTET_LENGTH(HEX_DECODE(BT)) FROM TC WHERE ID IN (1, 4, 5) ORDER BY ID;' \
     'ID HEX_ENCODE BASE64_ENCODE CAST OCTET_LENGTH|1 <blob> <blob> AB 2|HEX_ENCODE:|4142|BASE64_ENCODE:|QUI=|4 <blob> <blob> 0|HEX_ENCODE:|BASE64_ENCODE:|5 <null> <null> <null> <null>'
pin  '15 ... BASE64_DECODE of a text blob' 'SELECT CAST(BASE64_DECODE(BT) AS VARCHAR(10)) FROM TC WHERE ID = 2;' \
     'CAST|ABC'
pin  '15 ... HEX_DECODE of a UTF8 one' 'SELECT CAST(HEX_DECODE(BU) AS VARCHAR(10)) FROM TC WHERE ID = 1;' \
     'CAST|AB'
pin  '15 ... a blob'"'"'s length is checked per row' 'SELECT ID, HEX_DECODE(BT) FROM TC WHERE ID = 3;' \
     'ID HEX_DECODE|Statement failed, SQLSTATE = 22023|Invalid hex text length 3, should be multiple of 2'
pin  '15 ... BASE64_DECODE'"'"'s, an empty blob too' 'SELECT ID, BASE64_DECODE(BT) FROM TC WHERE ID = 4;' \
     'ID BASE64_DECODE|Statement failed, SQLSTATE = 22023|Wrong base64 text length 0, should be multiple of 4'
pin  '15 ... a bad digit' 'SELECT ID, HEX_DECODE(BT) FROM TC WHERE ID = 2;' \
     'ID HEX_DECODE|Statement failed, SQLSTATE = 22023|Invalid hex digit Q at position 1'
pin  '15 ... round trip over 70000 bytes' 'SELECT OCTET_LENGTH(BASE64_DECODE(BASE64_ENCODE(BT))), OCTET_LENGTH(HEX_DECODE(HEX_ENCODE(BT))) FROM TC WHERE ID = 8;' \
     'OCTET_LENGTH OCTET_LENGTH|70000 70000'
pin  '15 MAXVALUE / MINVALUE of a DECFLOAT(16) NaN: the first argument is kept' 'SELECT MAXVALUE(CAST('"'"'NaN'"'"' AS DECFLOAT(16)), 1), MINVALUE(CAST('"'"'NaN'"'"' AS DECFLOAT(16)), 1), MAXVALUE(1, CAST('"'"'NaN'"'"' AS DECFLOAT(16))), MINVALUE(1, CAST('"'"'NaN'"'"' AS DECFLOAT(16))) FROM RDB$DATABASE;' \
     'MAXVALUE MINVALUE MAXVALUE MINVALUE|NaN NaN 1 1'
pin  '15 ... a NaN past the first is passed over' 'SELECT MAXVALUE(1, CAST('"'"'NaN'"'"' AS DECFLOAT(16)), 2), MINVALUE(5, CAST('"'"'NaN'"'"' AS DECFLOAT(16)), 2), MAXVALUE(CAST('"'"'NaN'"'"' AS DECFLOAT(16)), CAST('"'"'Inf'"'"' AS DECFLOAT(16))), GREATEST(1, A, 3, 2) FROM TN WHERE ID = 1;' \
     'MAXVALUE MINVALUE MAXVALUE GREATEST|2 2 NaN 3'
pin  '15 a DECFLOAT(16) NaN is equal to every number' 'SELECT IIF(A > 1, '"'"'T'"'"', '"'"'F'"'"'), IIF(A = 1, '"'"'T'"'"', '"'"'F'"'"'), IIF(1 >= A, '"'"'T'"'"', '"'"'F'"'"'), IIF(A < X, '"'"'T'"'"', '"'"'F'"'"'), IIF(A = I8, '"'"'T'"'"', '"'"'F'"'"'), IIF(A <> A, '"'"'T'"'"', '"'"'F'"'"') FROM TN WHERE ID = 1;' \
     'CASE CASE CASE CASE CASE CASE|F T T F T F'
pin  '15 ... in a WHERE' 'SELECT ID FROM TN WHERE A = 5 ORDER BY ID;' \
     'ID|1|3'
pin  '15 ... <, <> find no NaN row' 'SELECT ID FROM TN WHERE A < 5 OR A <> 5 ORDER BY ID;' \
     'ID|2'
pin  '15 ... IN, BETWEEN' 'SELECT ID FROM TN WHERE A IN (7, 8) AND A BETWEEN 0 AND 1 ORDER BY ID;' \
     'ID|1'
pin  'CONTROL 15 beside a DECFLOAT(34) it raises' 'SELECT IIF(A > B, '"'"'T'"'"', '"'"'F'"'"') FROM TN WHERE ID = 1;' \
     'CASE|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation.'
pin  'CONTROL 15 ... and so does a DECFLOAT(34) NaN' 'SELECT MAXVALUE(1, B) FROM TN WHERE ID = 2;' \
     'MAXVALUE|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation.'
rec  '15 RECORDED a signalling or negative NaN literal cast is refused' 'SELECT MAXVALUE(CAST('"'"'sNaN'"'"' AS DECFLOAT(16)), 1) FROM RDB$DATABASE;' \
     'MAXVALUE|sNaN' 'MAXVALUE|Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin  '15 UNICODE_VAL / ASCII_VAL of a blob of 32767 bytes answer' 'SELECT UNICODE_VAL(BT), ASCII_VAL(BN), UNICODE_VAL(BU) FROM TC WHERE ID = 6;' \
     'UNICODE_VAL ASCII_VAL UNICODE_VAL|97 97 97'
pin  '15 ... of 32768 bytes: the blob truncation' 'SELECT UNICODE_VAL(BT) FROM TC WHERE ID = 7;' \
     'UNICODE_VAL|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-blob truncation when converting to a string: length limit exceeded'
pin  '15 ... ASCII_VAL of a binary one alike' 'SELECT ASCII_VAL(BN) FROM TC WHERE ID = 7;' \
     'ASCII_VAL|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-blob truncation when converting to a string: length limit exceeded'
pin  '15 ... a UTF8 one' 'SELECT UNICODE_VAL(BU) FROM TC WHERE ID = 7;' \
     'UNICODE_VAL|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-blob truncation when converting to a string: length limit exceeded'
pin  '15 ... 70000 bytes' 'SELECT ASCII_VAL(BT) FROM TC WHERE ID = 8;' \
     'ASCII_VAL|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-blob truncation when converting to a string: length limit exceeded'
pin  'CONTROL 15 ... a NULL blob operand answers NULL' 'SELECT UNICODE_VAL(BT), ASCII_VAL(BN) FROM TC WHERE ID = 5;' \
     'UNICODE_VAL ASCII_VAL|<null> <null>'
pin  '15 UNICODE_VAL of bytes that are no UTF-8: Malformed string' 'SELECT UNICODE_VAL(x'"'"'FF'"'"') FROM RDB$DATABASE;' \
     'UNICODE_VAL|Statement failed, SQLSTATE = 22000|Malformed string'
pin  '15 ... anywhere in the value' 'SELECT UNICODE_VAL(x'"'"'41FF'"'"') FROM RDB$DATABASE;' \
     'UNICODE_VAL|Statement failed, SQLSTATE = 22000|Malformed string'
pin  '15 an INT128 of 35 digits has no DECFLOAT(34)' 'SELECT CAST(CAST(12345678901234567890123456789012345 AS INT128) AS DECFLOAT(34)) FROM RDB$DATABASE;' \
     'CAST|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation.'
pin  '15 ... an exact one neither' 'SELECT CAST(CAST(10000000000000000000000000000000000000 AS INT128) AS DECFLOAT(34)) FROM RDB$DATABASE;' \
     'CAST|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation.'
pin  '15 ... beside a DECFLOAT in MAXVALUE' 'SELECT MAXVALUE(CAST(170141183460469231731687303715884105727 AS INT128), CAST(1 AS DECFLOAT(34))) FROM RDB$DATABASE;' \
     'MAXVALUE|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation.'
pin  '15 ... in an addition' 'SELECT CAST(12345678901234567890123456789012345 AS INT128) + CAST(0 AS DECFLOAT(34)) FROM RDB$DATABASE;' \
     'ADD|Statement failed, SQLSTATE = 22000|Decimal float invalid operation. An indeterminant error occurred during an operation.'
pin  'CONTROL 15 thirty-four digits convert' 'SELECT CAST(CAST(1234567890123456789012345678901234 AS INT128) AS DECFLOAT(34)), CAST(CAST(12345678901234567890123 AS INT128) AS DECFLOAT(16)) FROM RDB$DATABASE;' \
     'CAST CAST|1234567890123456789012345678901234 1.234567890123457E+22'
dpin '15 a blob at a NUMBER position describes as a text there' 'SELECT LPAD('"'"'a'"'"', BL), LEFT('"'"'abcdef'"'"', BL), DATEADD(BL DAY TO DATE '"'"'2020-01-01'"'"'), POSITION('"'"'a'"'"', '"'"'abc'"'"', BL) FROM TB WHERE ID = 2;' \
     '01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 65533 charset: 0 SYSTEM.NONE| : name: LPAD alias: LPAD|02: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 6 charset: 0 SYSTEM.NONE| : name: LEFT alias: LEFT|03: sqltype: 570 SQL DATE Nullable scale: 0 subtype: 0 len: 4| : name: DATEADD alias: DATEADD|04: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4| : name: POSITION alias: POSITION'
pin  '15 LPAD'"'"'s length: conversion error from string "BLOB"' 'SELECT LPAD('"'"'a'"'"', BL) FROM TB WHERE ID = 1;' \
     'LPAD|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '15 LEFT'"'"'s count' 'SELECT LEFT('"'"'abcdef'"'"', BL) FROM TB WHERE ID = 1;' \
     'LEFT|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '15 SUBSTRING'"'"'s FOR' 'SELECT SUBSTRING('"'"'abcdef'"'"' FROM 1 FOR BL) FROM TB WHERE ID = 1;' \
     'SUBSTRING|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '15 DATEADD'"'"'s amount' 'SELECT DATEADD(BL DAY TO DATE '"'"'2020-01-01'"'"') FROM TB WHERE ID = 1;' \
     'DATEADD|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  '15 OVERLAY'"'"'s FROM' 'SELECT OVERLAY('"'"'abc'"'"' PLACING '"'"'x'"'"' FROM BL) FROM TB WHERE ID = 1;' \
     'OVERLAY|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"'
pin  'CONTROL 15 ... a NULL blob answers NULL' 'SELECT LPAD('"'"'a'"'"', BL), DATEADD(BL DAY TO DATE '"'"'2020-01-01'"'"') FROM TB WHERE ID = 2;' \
     'LPAD DATEADD|<null> <null>'
rec  '15 RECORDED SUBSTRING FROM a blob (-607 at prepare) is refused' 'SELECT SUBSTRING('"'"'abcdef'"'"' FROM BL) FROM TB WHERE ID = 1;' \
     'Statement failed, SQLSTATE = HY000|Dynamic SQL Error|-SQL error code = -607|-Array/BLOB/DATE data types not allowed in arithmetic' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
rec  '15 RECORDED ROUND'"'"'s places from a blob is refused' 'SELECT ROUND(1.55, BL) FROM TB WHERE ID = 1;' \
     'ROUND|Statement failed, SQLSTATE = 22018|conversion error from string "BLOB"' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo '--- 13. RECORDED: the shapes this server still refuses (clean refusals)'
rec  '13 SUBSTRING ... SIMILAR' 'SELECT SUBSTRING('"'"'abcdef'"'"' SIMILAR '"'"'a#"bc#"%'"'"' ESCAPE '"'"'#'"'"') FROM RDB$DATABASE;' \
     'SUBSTRING|bc' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
rec  '13 BLOB_APPEND' 'SELECT BLOB_APPEND(NULL, '"'"'a'"'"', '"'"'b'"'"') FROM RDB$DATABASE;' \
     'BLOB_APPEND|<blob>|BLOB_APPEND:|ab' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error' sessb
rec  '13 CAST ... FORMAT to text' 'SELECT CAST(DATE '"'"'2024-02-29'"'"' AS VARCHAR(30) FORMAT '"'"'DD/MM/YY'"'"') FROM RDB$DATABASE;' \
     'CAST|29/02/24' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
rec  '13 CAST ... FORMAT from text' 'SELECT CAST('"'"'29.02.2024'"'"' AS DATE FORMAT '"'"'DD.MM.YYYY'"'"') FROM RDB$DATABASE;' \
     'CAST|2024-02-29' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-builtins-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 325 ]; then echo "FAIL only $ran checks ran (floor 325)"; fail=1; fi
exit $fail
