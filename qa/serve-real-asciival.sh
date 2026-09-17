#!/bin/bash
# ASCII_VAL(s) in the SysFn scalar machinery: the SMALLINT code of the
# first BYTE OF THE OPERAND'S STORED REPRESENTATION - 0 for an empty
# string, NULL for NULL. Joins MOD / ABS / SIGN.
#
# THE CHARACTER SET DECIDES, and all three behaviours are measured:
#   * a BYTE CARRIER (NONE / OCTETS / ASCII): the decoded char IS the
#     stored byte, so its code is the answer (a NONE 0xE9 is 233);
#   * a TABLED SINGLE-BYTE page (WIN1252, ...): the STORED CODEPAGE BYTE
#     - a WIN1252 0x9F is 159, NOT the 376 (U+0178) its decoded character
#     would give;
#   * a MULTIBYTE set (UTF8): the engine RAISES SQLSTATE 22018
#     *Cannot transliterate character between character sets* when the
#     FIRST character occupies more than one byte, and answers the plain
#     byte when it does not (`'aé'` is 97 - the SECOND character being
#     multibyte is not the test).
# A bare LITERAL takes the ATTACHMENT's set, which is why `ASCII_VAL('é')`
# raises under a UTF8 attachment and answers 195 under WIN1252 or NONE
# (the same two octets, read as that set). The raise is PER ROW and lands
# in DELIVERY order - under ORDER BY the rows before the offending one are
# delivered first, and a row the WHERE excludes never raises at all.
#
# THE HEADER THIS REPLACES WAS WRONG ABOUT THE ENGINE, and the gate could
# not have caught it: it recorded "a multibyte first character takes its
# code point where the engine TAKES THE FIRST BYTE", but the engine
# RAISES. The three checks below it only ever ran over a NONE database
# with a plain VARCHAR(5) column - a byte carrier, the one case that
# already agreed - so the gate stayed green over two real wrong answers
# (233 for a UTF8 'é' the engine refuses, and 376 for a WIN1252 0x9F the
# engine calls 159) and one refusal (`ASCII_VAL(NULL)`, a bare 42000
# where the engine answers NULL). The fixture below therefore carries
# every charset, not just the agreeing one.
#
# (ASCII_CHAR is still a follow-up: its CHAR(1) NONE result needs fc's
# byte-carrier value-width handling for a byte 128..255, a separate
# charset slice.)
#
#   qa/serve-real-asciival.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4948}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-asciival-crab.fdb"; B="$D/fc-asciival-engine.fdb"
LOG="/tmp/fc-serve-asciival-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
# THE CHARSET FIXTURE IS BUILT BY THE ENGINE, BEFORE THE SERVER STARTS.
# The `SET` script below is applied THROUGH fire-crab, which is fine for
# plain ASCII rows but cannot execute the `_UTF8 x'..'` introducer literals
# these cells need - applied that way, only the all-NULL row landed and
# every charset cell compared an empty result to the engine's (caught by
# the "four rows exist" control, and silently, because that isql call runs
# without `-b`). Building it here keeps fire-crab out of its own test data:
# it only ever READS these rows.
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE TX (ID INTEGER,
                 U  VARCHAR(10) CHARACTER SET UTF8,
                 W  VARCHAR(10) CHARACTER SET WIN1252,
                 N  VARCHAR(10) CHARACTER SET NONE,
                 O  VARCHAR(10) CHARACTER SET OCTETS,
                 CU CHAR(4)     CHARACTER SET UTF8,
                 A8 VARCHAR(10) CHARACTER SET ASCII);
COMMIT;
INSERT INTO TX VALUES (1, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO TX VALUES (2, _UTF8 x'4142', _WIN1252 x'4142', _NONE x'4142', _OCTETS x'4142', _UTF8 x'4142', _ASCII x'42');
INSERT INTO TX VALUES (3, _UTF8 x'C3A9', _WIN1252 x'9F',   _NONE x'E9',   _OCTETS x'E9',   _UTF8 x'C3A9', _ASCII x'41');
INSERT INTO TX VALUES (4, _UTF8 x'5A',   _WIN1252 x'5A',   _NONE x'5A',   _OCTETS x'5A',   _UTF8 x'5A',   _ASCII x'5A');
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

SET="CREATE TABLE T(C VARCHAR(5));
INSERT INTO T VALUES ('hi');
INSERT INTO T VALUES ('Zoo');
INSERT INTO T VALUES ('');
COMMIT;"
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

cat > "$D/v.sql" <<'SQL'
SET LIST ON;
SELECT ASCII_VAL('A') A, ASCII_VAL('abc') B, ASCII_VAL('0') C, ASCII_VAL('') E, ASCII_VAL(' ') SP FROM RDB$DATABASE;
SELECT COALESCE(ASCII_VAL(C), -1) V FROM T ORDER BY C;
SQL
vof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/v.sql" 2>&1 | norm; }
check "ASCII_VAL values (letters, digit, space, empty, columns)" \
    "$(vof "127.0.0.1/$PORT:$A")" "$(vof "127.0.0.1/$REAL:$B")"

cat > "$D/d.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT ASCII_VAL('A'), ASCII_VAL(C) FROM T ROWS 1;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/d.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe - SMALLINT" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# --- THE CHARACTER SET DECIDES -------------------------------------------
# Every cell runs on BOTH servers and must answer identically - a raise
# included, message for message. `runsql` keeps the transport fixed (TCP to
# both) and `-ch` varies the ATTACHMENT, which is what types a bare literal.
runsql() { # <target> <sql> [charset]
    local ch=()
    [ -n "${3:-}" ] && ch=(-ch "$3")
    printf 'SET LIST ON;\n%s;\n' "$2" \
        | "$ISQL" -q -b "${ch[@]}" -user "$U" -pas "$P" "$1" 2>&1 | norm
}
cell() { # <label> <sql> [charset]
    check "$1" \
        "$(runsql "127.0.0.1/$PORT:$A" "$2" "${3:-}")" \
        "$(runsql "127.0.0.1/$REAL:$B" "$2" "${3:-}")"
}
# the fixture must actually hold the high bytes, or every cell below would
# compare one server's error to the other's and score a vacuous OK
cell "fixture: four rows exist"        "SELECT COUNT(*) AS N FROM TX"
cell "fixture: the UTF8 e-acute is 2 bytes" "SELECT OCTET_LENGTH(U) AS N FROM TX WHERE ID=3"
cell "fixture: the WIN1252 0x9F is 1 byte"  "SELECT OCTET_LENGTH(W) AS N FROM TX WHERE ID=3"

for CH in "" "UTF8" "WIN1252"; do
    l="${CH:-attNONE}"
    # a bare literal takes the ATTACHMENT's set: UTF8 raises, the
    # single-byte and carrier attachments read the same two octets as
    # their own characters and answer 195
    cell "literal e-acute @$l"      "SELECT ASCII_VAL('é') AS N FROM RDB\$DATABASE" "$CH"
    # a COLUMN takes its OWN set, whatever the attachment is
    cell "UTF8 col (multibyte) @$l" "SELECT ASCII_VAL(U) AS N FROM TX WHERE ID=3" "$CH"
    cell "WIN1252 col 0x9F @$l"     "SELECT ASCII_VAL(W) AS N FROM TX WHERE ID=3" "$CH"
    cell "NONE col 0xE9 @$l"        "SELECT ASCII_VAL(N) AS N FROM TX WHERE ID=3" "$CH"
    cell "OCTETS col 0xE9 @$l"      "SELECT ASCII_VAL(O) AS N FROM TX WHERE ID=3" "$CH"
    cell "CHAR(4) UTF8 multibyte @$l" "SELECT ASCII_VAL(CU) AS N FROM TX WHERE ID=3" "$CH"
done

# the ASCII side of every set must be untouched - these agreed before the
# charset seam existed and must go on agreeing
cell "UTF8 col 'AB'"      "SELECT ASCII_VAL(U) AS N FROM TX WHERE ID=2"
cell "WIN1252 col 'AB'"   "SELECT ASCII_VAL(W) AS N FROM TX WHERE ID=2"
cell "NONE col 'AB'"      "SELECT ASCII_VAL(N) AS N FROM TX WHERE ID=2"
cell "OCTETS col 'AB'"    "SELECT ASCII_VAL(O) AS N FROM TX WHERE ID=2"
cell "ASCII col"          "SELECT ASCII_VAL(A8) AS N FROM TX WHERE ID=2"
cell "CHAR(4) UTF8 'AB'"  "SELECT ASCII_VAL(CU) AS N FROM TX WHERE ID=2"

# edges
cell "empty literal is 0"        "SELECT ASCII_VAL('') AS N FROM RDB\$DATABASE"
cell "a bare NULL literal"       "SELECT ASCII_VAL(NULL) AS N FROM RDB\$DATABASE"
cell "a NULL-valued UTF8 column" "SELECT ASCII_VAL(U) AS N FROM TX WHERE ID=1"
cell "a NULL CAST"               "SELECT ASCII_VAL(CAST(NULL AS VARCHAR(4))) AS N FROM RDB\$DATABASE"
cell "COALESCE around a NULL"    "SELECT COALESCE(ASCII_VAL(U), -1) AS N FROM TX WHERE ID=1"
cell "multi-char ASCII"          "SELECT ASCII_VAL('AB') AS N FROM RDB\$DATABASE"
cell "only the FIRST char counts" "SELECT ASCII_VAL('aé') AS N FROM RDB\$DATABASE"
cell "a CAST to OCTETS"          "SELECT ASCII_VAL(CAST(U AS VARCHAR(10) CHARACTER SET OCTETS)) AS N FROM TX WHERE ID=3"

# the raise is PER ROW and lands in DELIVERY order
cell "every row, ID order"       "SELECT ID, ASCII_VAL(U) AS N FROM TX ORDER BY ID"
cell "every row, ID DESC"        "SELECT ID, ASCII_VAL(U) AS N FROM TX ORDER BY ID DESC"
cell "the raiser FILTERED OUT"   "SELECT ID, ASCII_VAL(U) AS N FROM TX WHERE ID <> 3 ORDER BY ID"
cell "WIN1252, every row"        "SELECT ID, ASCII_VAL(W) AS N FROM TX ORDER BY ID"
cell "NONE, every row"           "SELECT ID, ASCII_VAL(N) AS N FROM TX ORDER BY ID"
# a WHERE term over a raiser: the engine raises mid-scan, and an earlier
# AND that excludes the offending row means neither server ever reaches it
cell "WHERE over the raiser"     "SELECT COUNT(*) AS N FROM TX WHERE ASCII_VAL(U) > 0"
cell "WHERE, raiser excluded"    "SELECT COUNT(*) AS N FROM TX WHERE ID <> 3 AND ASCII_VAL(U) > 0"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
