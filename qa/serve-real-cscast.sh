#!/bin/bash
# CAST(<value> AS CHAR|VARCHAR(n) CHARACTER SET <cs>) - the cast that
# converts a value between CHARACTER SETS, and the three error classes
# the conversion can raise. Probed against the engine and traced:
#
#   * the DESCRIBE names the target set and its BYTES: a VARCHAR(3)
#     CHARACTER SET UTF8 is len 12 charset 4 where the WIN1252 one is
#     len 3 charset 53 - and under a REAL attachment charset the engine
#     re-announces every result in the ATTACHMENT's set EXCEPT an
#     OCTETS one, which keeps its own (measured under NONE/UTF8/WIN1252)
#   * a BYTE-CARRIER destination (NONE, OCTETS) takes the source's
#     octets whatever they are: UTF8 'café' into NONE is its five UTF-8
#     bytes
#   * from a byte carrier INTO a real set the bytes must SPELL it, or it
#     is SQLSTATE 22000 "Malformed string" - x'41FF' into UTF8, any byte
#     past 0x7F into ASCII. A single-byte destination has an image for
#     every octet, so x'8182' into WIN1252 answers
#   * between two REAL sets the CHARACTERS travel, and one with no image
#     in the destination is 22018 "Cannot transliterate character
#     between character sets" - the OTHER vector for the same value
#   * TRANSLITERATION COMES FIRST: five untranslatable characters into a
#     VARCHAR(2) is the 22018, never the 22001 the width would earn
#   * the width is counted in CHARACTERS OF THE TARGET, and the overflow
#     that may be dropped is the target set's PAD: `x'41202020'` into a
#     VARCHAR(2) OCTETS RAISES where `x'41000000'` fits, because OCTETS
#     pads with a NUL. A CHAR target fills with the same byte
#   * an undefined character set NAME is the engine's -204 at prepare,
#     "CHARACTER SET "PUBLIC"."NOSUCH" is not defined"
#
# Boundaries (recorded, all refuse rather than answer): a character set
# the engine has that this server carries no table for (DOS437,
# UNICODE_FSS, the multibyte pages), a COLLATE naming anything but the
# set's own collation, `CAST(... AS BLOB SUB_TYPE TEXT CHARACTER SET
# ...)`, the `_WIN1252 'literal'` introducer, a parameter under the
# cast, and the two width refusals (0 and past the byte limit), where
# the engine's -842 / -204 name the number and this server's is generic.
#
#   qa/serve-real-cscast.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4914}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-cscast-crab.fdb"
B="$D/fc-cscast-engine.fdb"
LOG="/tmp/fc-serve-cscast-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
# -a: a value with high bytes makes grep call the stream binary and
# print nothing but a warning - which reads as an empty answer on BOTH
# sides and hides a real difference
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a sqltype | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a sqltype | norm)
    check "$1" "$c" "$e"
}

# ---- the describe -------------------------------------------------------
bothd "the describe names the target set and its BYTES" \
  "SELECT CAST('ab' AS VARCHAR(3) CHARACTER SET UTF8), CAST('ab' AS VARCHAR(3) CHARACTER SET WIN1252), CAST('ab' AS VARCHAR(3) CHARACTER SET OCTETS), CAST('ab' AS VARCHAR(3) CHARACTER SET NONE) FROM RDB\$DATABASE;"
bothd "a CHAR target, and a rendered number in a named set" \
  "SELECT CAST('ab' AS CHAR(3) CHARACTER SET WIN1252), CAST(42 AS VARCHAR(5) CHARACTER SET UTF8) FROM RDB\$DATABASE;"

# The same describe under a UTF8 ATTACHMENT, where the engine re-announces
# every result in the ATTACHMENT's character set - except an OCTETS one,
# which keeps its own, and a NONE one, which keeps its bytes.
bothu() {
    # the attachment charset comes from isql's -ch, not a SET NAMES before a
    # CONNECT: this server rejects the login isql sends out of a CONNECT
    # statement's `USER '...'` clause - the client passes the QUOTES through
    # and the identity check here is exact, where the engine dequotes
    # (a recorded divergence, found gating this)
    e=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a sqltype | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a sqltype | norm)
    check "$1" "$c" "$e"
}
bothu "under a UTF8 attachment the named set is re-announced in it - except OCTETS and NONE" \
  "SELECT CAST('ab' AS VARCHAR(3) CHARACTER SET WIN1252), CAST('ab' AS VARCHAR(3) CHARACTER SET OCTETS), CAST('ab' AS VARCHAR(3) CHARACTER SET NONE), CAST('ab' AS VARCHAR(3) CHARACTER SET ASCII) FROM RDB\$DATABASE;"

# ---- the literal cases --------------------------------------------------
both "the value, and the name written every way the engine takes it" \
  "SELECT CAST('ab' AS VARCHAR(3) CHARACTER SET WIN1252), CAST('ab' AS VARCHAR(3) CHARACTER SET win1252), CAST('ab' AS VARCHAR(3) CHARACTER SET \"WIN1252\"), CAST('a' AS VARCHAR(2) CHARACTER SET BINARY), CAST('a' AS VARCHAR(2) CHARACTER SET LATIN1) FROM RDB\$DATABASE;"
both "a byte-carrier destination takes the octets" \
  "SELECT CAST('ab' AS VARCHAR(3) CHARACTER SET OCTETS), CAST('ab' AS CHAR(4) CHARACTER SET OCTETS), CAST('ab' AS CHAR(4) CHARACTER SET NONE) FROM RDB\$DATABASE;"
both "the width fits in the TARGET's characters, and the pad decides the drop" \
  "SELECT '['||CAST('ab   ' AS VARCHAR(3) CHARACTER SET WIN1252)||']' FROM RDB\$DATABASE; SELECT CAST('abcdef' AS VARCHAR(3) CHARACTER SET WIN1252) FROM RDB\$DATABASE; SELECT CAST(x'41202020' AS VARCHAR(2) CHARACTER SET OCTETS) FROM RDB\$DATABASE; SELECT CAST(x'41000000' AS VARCHAR(2) CHARACTER SET OCTETS) FROM RDB\$DATABASE;"
both "bytes that do not spell the destination are Malformed string" \
  "SELECT CAST(x'4142' AS VARCHAR(4) CHARACTER SET UTF8) FROM RDB\$DATABASE; SELECT CAST(x'41FF' AS VARCHAR(4) CHARACTER SET UTF8) FROM RDB\$DATABASE; SELECT CAST(x'41FF' AS VARCHAR(4) CHARACTER SET ASCII) FROM RDB\$DATABASE; SELECT CAST(x'8182' AS VARCHAR(4) CHARACTER SET WIN1252) FROM RDB\$DATABASE;"
both "a rendered number or date converts like any text" \
  "SELECT CAST(3.14 AS VARCHAR(6) CHARACTER SET WIN1252), CAST(DATE'2020-06-15' AS VARCHAR(12) CHARACTER SET OCTETS), CAST(TRUE AS VARCHAR(6) CHARACTER SET OCTETS) FROM RDB\$DATABASE;"
both "an undefined character set name is the engine's -204" \
  "SELECT CAST('1' AS VARCHAR(2) CHARACTER SET NOSUCH) FROM RDB\$DATABASE;"
both "a QUOTED name is matched as written, so the lower-case one is undefined" \
  "SELECT CAST('1' AS VARCHAR(2) CHARACTER SET \"win1252\") FROM RDB\$DATABASE;"
both "a codepage-to-codepage move keeps a shared character and refuses a private one" \
  "SELECT OCTET_LENGTH(CAST(CAST(x'E9' AS VARCHAR(4) CHARACTER SET WIN1250) AS VARCHAR(4) CHARACTER SET WIN1252)) FROM RDB\$DATABASE; SELECT CAST(CAST(x'F8' AS VARCHAR(4) CHARACTER SET WIN1250) AS VARCHAR(4) CHARACTER SET WIN1252) FROM RDB\$DATABASE;"
both "the empty value, and a NUL byte that IS a character" \
  "SELECT OCTET_LENGTH(CAST('' AS VARCHAR(2) CHARACTER SET OCTETS)), OCTET_LENGTH(CAST('' AS CHAR(2) CHARACTER SET OCTETS)), OCTET_LENGTH(CAST(x'0041' AS VARCHAR(4) CHARACTER SET UTF8)) FROM RDB\$DATABASE;"
both "NULL casts to NULL in any set" \
  "SELECT CAST(NULL AS VARCHAR(3) CHARACTER SET OCTETS), CAST(NULL AS CHAR(3) CHARACTER SET WIN1252) FROM RDB\$DATABASE;"

# ---- stored columns -----------------------------------------------------
mk() { cat <<'SQL'
CREATE TABLE T (ID INTEGER, S VARCHAR(20) CHARACTER SET UTF8, W VARCHAR(20) CHARACTER SET WIN1252,
                N VARCHAR(20) CHARACTER SET NONE, O CHAR(4) CHARACTER SET OCTETS,
                B BLOB SUB_TYPE TEXT CHARACTER SET UTF8);
COMMIT;
INSERT INTO T VALUES (1, 'abc', 'abc', 'abc', x'61620000', 'blob one');
INSERT INTO T VALUES (2, 'café', CAST(x'E9' AS VARCHAR(20) CHARACTER SET WIN1252), CAST(x'41FF' AS VARCHAR(20) CHARACTER SET NONE), x'41FF0000', 'café');
INSERT INTO T VALUES (3, 'Ω', 'z', 'z', x'81820000', 'Ω');
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
both "the rows landed the same on both sides" \
  "SELECT ID, S, W, N, O, OCTET_LENGTH(S), OCTET_LENGTH(W), OCTET_LENGTH(N) FROM T ORDER BY ID;"
both "a UTF8 column into a single-byte set - and the character with no image" \
  "SELECT CAST(S AS VARCHAR(6) CHARACTER SET WIN1252), OCTET_LENGTH(CAST(S AS VARCHAR(6) CHARACTER SET WIN1252)) FROM T WHERE ID = 2; SELECT CAST(S AS VARCHAR(6) CHARACTER SET WIN1252) FROM T WHERE ID = 3; SELECT CAST(S AS VARCHAR(6) CHARACTER SET ASCII) FROM T WHERE ID = 2;"
both "a single-byte column into UTF8 grows its bytes" \
  "SELECT CAST(W AS VARCHAR(6) CHARACTER SET UTF8), OCTET_LENGTH(CAST(W AS VARCHAR(6) CHARACTER SET UTF8)) FROM T WHERE ID = 2;"
both "a UTF8 column into a byte carrier keeps its OCTETS" \
  "SELECT OCTET_LENGTH(CAST(S AS VARCHAR(9) CHARACTER SET NONE)), OCTET_LENGTH(CAST(S AS VARCHAR(9) CHARACTER SET OCTETS)), CAST(S AS VARCHAR(9) CHARACTER SET OCTETS) FROM T WHERE ID = 2;"
both "a NONE / OCTETS column into UTF8: the bytes must spell it" \
  "SELECT CAST(N AS VARCHAR(6) CHARACTER SET UTF8) FROM T WHERE ID = 1; SELECT CAST(N AS VARCHAR(6) CHARACTER SET UTF8) FROM T WHERE ID = 2; SELECT CAST(O AS VARCHAR(6) CHARACTER SET UTF8) FROM T WHERE ID = 1; SELECT CAST(O AS VARCHAR(6) CHARACTER SET UTF8) FROM T WHERE ID = 2;"
both "an OCTETS column into a single-byte set answers for every octet" \
  "SELECT CAST(O AS VARCHAR(6) CHARACTER SET WIN1252), OCTET_LENGTH(CAST(O AS VARCHAR(6) CHARACTER SET WIN1252)) FROM T WHERE ID = 3; SELECT CAST(O AS VARCHAR(6) CHARACTER SET ASCII) FROM T WHERE ID = 3;"
both "transliteration comes BEFORE the width" \
  "SELECT CAST(S AS VARCHAR(1) CHARACTER SET WIN1252) FROM T WHERE ID = 3; SELECT CAST(S AS VARCHAR(1) CHARACTER SET WIN1252) FROM T WHERE ID = 2;"

# ---- the result is a value of that character set ------------------------
both "the OCTETS laws apply to the cast's result" \
  "SELECT 'y' FROM RDB\$DATABASE WHERE CAST('A' AS CHAR(2) CHARACTER SET OCTETS) = x'4100'; SELECT 'n' FROM RDB\$DATABASE WHERE CAST('A' AS CHAR(2) CHARACTER SET OCTETS) = 'A '; SELECT 'like' FROM RDB\$DATABASE WHERE CAST('ab' AS CHAR(4) CHARACTER SET OCTETS) LIKE x'61620000'; SELECT 'nolike' FROM RDB\$DATABASE WHERE CAST('ab' AS CHAR(4) CHARACTER SET OCTETS) LIKE x'6162';"
both "one cast operand makes the whole expression binary" \
  "SELECT OCTET_LENGTH(CAST('a' AS VARCHAR(2) CHARACTER SET OCTETS) || 'b'), CAST('a' AS VARCHAR(2) CHARACTER SET OCTETS) || 'b' FROM RDB\$DATABASE;"
bothd "and the describe of that combination" \
  "SELECT CAST('a' AS VARCHAR(2) CHARACTER SET OCTETS) || 'b', COALESCE(NULL, CAST('a' AS VARCHAR(2) CHARACTER SET WIN1252)) FROM RDB\$DATABASE;"
both "UPPER over a cast to OCTETS is the identity" \
  "SELECT UPPER(CAST('ab' AS VARCHAR(4) CHARACTER SET OCTETS)), UPPER(CAST('ab' AS VARCHAR(4) CHARACTER SET WIN1252)) FROM RDB\$DATABASE;"
both "a cast in WHERE, ORDER BY and GROUP BY" \
  "SELECT ID FROM T WHERE CAST(S AS VARCHAR(6) CHARACTER SET NONE) = 'abc'; SELECT ID FROM T WHERE CAST(O AS VARCHAR(6) CHARACTER SET OCTETS) = x'61620000'; SELECT CAST(W AS VARCHAR(6) CHARACTER SET OCTETS) FROM T ORDER BY 1; SELECT CAST(N AS VARCHAR(6) CHARACTER SET OCTETS), COUNT(*) FROM T GROUP BY 1 ORDER BY 1;"

both "a text BLOB source converts like any text" \
  "SELECT CAST(B AS VARCHAR(9) CHARACTER SET WIN1252), OCTET_LENGTH(CAST(B AS VARCHAR(9) CHARACTER SET OCTETS)) FROM T WHERE ID = 2; SELECT CAST(B AS VARCHAR(9) CHARACTER SET WIN1252) FROM T WHERE ID = 3;"
both "the text functions read the cast's result in ITS set" \
  "SELECT CHAR_LENGTH(CAST(S AS VARCHAR(9) CHARACTER SET NONE)), OCTET_LENGTH(CAST(S AS VARCHAR(9) CHARACTER SET NONE)), CHAR_LENGTH(CAST(S AS VARCHAR(9) CHARACTER SET WIN1252)), OCTET_LENGTH(CAST(S AS VARCHAR(9) CHARACTER SET WIN1252)) FROM T WHERE ID = 2;"
both "a cast of a cast" \
  "SELECT CAST(CAST(S AS VARCHAR(9) CHARACTER SET WIN1252) AS VARCHAR(9) CHARACTER SET UTF8), OCTET_LENGTH(CAST(CAST(S AS VARCHAR(9) CHARACTER SET WIN1252) AS VARCHAR(9) CHARACTER SET OCTETS)) FROM T WHERE ID = 2;"

# ---- DML ----------------------------------------------------------------
both "a cast VALUE stores, updates and reads back" \
  "INSERT INTO T VALUES (4, CAST(x'6566' AS VARCHAR(6) CHARACTER SET UTF8), CAST(x'FE' AS VARCHAR(6) CHARACTER SET WIN1252), 'n4', CAST('ab' AS CHAR(4) CHARACTER SET OCTETS), NULL); COMMIT; UPDATE T SET O = CAST(x'0102' AS CHAR(4) CHARACTER SET OCTETS) WHERE ID = 4; COMMIT; SELECT ID, S, W, N, O, OCTET_LENGTH(W) FROM T WHERE ID = 4;"

# ---- the engine reads fire-crab's file ----------------------------------
eng_q="SET LIST ON; SELECT ID, S, W, N, O, OCTET_LENGTH(S) AS OS, OCTET_LENGTH(W) AS OW FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads the rows fire-crab's casts wrote" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    case "$r" in
        *"Statement failed"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     fc: $r"; fail=1 ;;
    esac
}
refuses "a character set with no table here refuses (DOS437)" \
  "SELECT CAST('a' AS VARCHAR(2) CHARACTER SET DOS437) FROM RDB\$DATABASE;"
refuses "... and UNICODE_FSS with it" \
  "SELECT CAST('a' AS VARCHAR(2) CHARACTER SET UNICODE_FSS) FROM RDB\$DATABASE;"
refuses "a COLLATE with no CHARACTER SET refuses" \
  "SELECT CAST('AB' AS VARCHAR(3) COLLATE UNICODE_CI) FROM RDB\$DATABASE;"
refuses "a COLLATE other than the set's own refuses" \
  "SELECT CAST('AB' AS VARCHAR(3) CHARACTER SET UTF8 COLLATE UNICODE_CI) FROM RDB\$DATABASE;"
# (a BLOB target is served - see serve-real-blobexpr.sh; a cast to a
# blob names the blob's OWN character set, not a transliteration of the
# result the way a CHAR target does)
refuses "the character-set introducer refuses" \
  "SELECT _WIN1252 'ab' FROM RDB\$DATABASE;"
refuses "a parameter under the cast refuses" \
  "SELECT CAST(? AS VARCHAR(3) CHARACTER SET OCTETS) FROM RDB\$DATABASE;"
refuses "a zero width refuses (the engine's -842)" \
  "SELECT CAST('a' AS VARCHAR(0) CHARACTER SET UTF8) FROM RDB\$DATABASE;"
refuses "a width past the byte limit refuses (the engine's -204)" \
  "SELECT CAST('a' AS VARCHAR(9000) CHARACTER SET UTF8) FROM RDB\$DATABASE;"
refuses "CHARACTER SET on a non-text target refuses" \
  "SELECT CAST('1' AS INTEGER CHARACTER SET UTF8) FROM RDB\$DATABASE;"
refuses "a cast to a named set in a VIEW body refuses" \
  "CREATE VIEW VC (ID, X) AS SELECT ID, CAST(S AS VARCHAR(9) CHARACTER SET OCTETS) FROM T;"
refuses "a cast to a named set inside a PSQL body refuses" \
  "EXECUTE BLOCK RETURNS (R VARCHAR(4) CHARACTER SET OCTETS) AS BEGIN R = CAST('ab' AS VARCHAR(4) CHARACTER SET OCTETS); SUSPEND; END"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
