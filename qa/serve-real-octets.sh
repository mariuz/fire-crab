#!/bin/bash
# BINARY (hex) literals and the OCTETS string laws. `x'…'` is CHAR(n)
# CHARACTER SET OCTETS - bytes, not text - and OCTETS is the one character set
# whose "space" is a NUL. Probed against the engine and traced to the source:
#
#   * the LITERAL: `x'48656C6C6F'` describes 452/len 5/charset 1 NOT NULL,
#     spaces inside are ignored, each segment needs an even digit count,
#     whitespace-separated segments continue one literal and an adjacent quote
#     does not; an odd or non-hex digit backtracks to a -104
#   * the PAD BYTE: a CHAR(4) OCTETS holding `x'6162'` reads back `61620000`,
#     where every other charset blank-pads (CVT_move, cvt.cpp:2069)
#   * COMPARISON pads with 0x00 as soon as EITHER side is binary and
#     transliterates neither (CVT2_compare, cvt2.cpp:438), so `x'4100' = 'A'`
#     is TRUE where `x'4120' = 'A'` is FALSE, and `x'41' < 'A '`
#   * UPPER/LOWER are IDENTITY - the binary texttype installs a byte copy
#     (intl_builtin.cpp:1025), where NONE and ASCII upcase the ASCII range
#   * TRIM's default character is the charset's space = one 0x00
#     (ExprNodes.cpp:12896 through intl_builtin.cpp:1516), so a 0x20 survives
#     and a 0x00 does not; LPAD/RPAD fill with the same byte
#   * LIKE has NO WILDCARDS over a binary LEFT operand: `%`/`_` are converted
#     from Unicode into the charset and binary's converter emits a leading
#     0x00, which the matcher's `sql_match_any &&` guard reads as "none"
#     (Collation.cpp:1025, intl_builtin.cpp:926, evl_string.h:352). The match
#     is literal over the FULL padded value, so a CHAR(4) holding `61620000`
#     matches `x'61620000'` and not `x'6162'`. A CHAR left operand keeps its
#     wildcards even when the pattern is binary.
#   * the RESULT CHARSET absorbs: one OCTETS operand makes the whole
#     concatenation / CASE / COALESCE / MIN binary (getResultTextType,
#     DataTypeUtil.cpp:59) - and a high byte then travels as ONE octet
#
# Boundaries (recorded, all refuse rather than answer): a LIKE pattern against
# a binary side that is not a literal - a parameter or an expression, where the
# engine answers - `CAST(<x> AS … CHARACTER SET OCTETS)`, which this server does
# not parse yet in any charset - a hex literal as a column DEFAULT - and a hex
# literal inside a PSQL body, which needs the BLR compiler to emit an OCTETS
# literal descriptor.
#
#   qa/serve-real-octets.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4913}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-octets-crab.fdb"
B="$D/fc-octets-engine.fdb"
LOG="/tmp/fc-serve-octets-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET NONE;
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# run one script against both servers and compare
both() {
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep sqltype | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep sqltype | norm)
    check "$1" "$c" "$e"
}

# ---- the literal itself -------------------------------------------------
bothd "the describe: CHAR of the BYTES at OCTETS, NOT NULL" \
  "SELECT x'48656C6C6F' FROM RDB\$DATABASE;"
both "the value, the empty literal, and the octet length" \
  "SELECT x'48656C6C6F', x'', OCTET_LENGTH(x'48656C6C6F'), CHARACTER_LENGTH(x'C3A9') FROM RDB\$DATABASE;"
both "spaces inside are ignored, whitespace-separated segments continue it" \
  "SELECT x'48 65 6C', x'4 8', x'41' '42' FROM RDB\$DATABASE;"
# A malformed literal BACKTRACKS in the engine, and what follows is then
# unparsable - both servers refuse at prepare with the same 42000 Dynamic SQL
# Error. The engine's message goes on to name the offending token (-104 with
# its line and column); fire-crab's refusal is generic, so the SHAPE of the
# refusal is what is compared here (recorded boundary).
head2() {
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm | cut -d'|' -f1-2)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm | cut -d'|' -f1-2)
    check "$1" "$c" "$e"
}
head2 "an ADJACENT quote does not continue it (refused)" \
  "SELECT x'41''42' FROM RDB\$DATABASE;"
head2 "an odd digit count refuses" "SELECT x'123' FROM RDB\$DATABASE;"
head2 "a non-hex digit refuses" "SELECT x'4G' FROM RDB\$DATABASE;"
both "the uppercase spelling is the same literal" "SELECT X'41' FROM RDB\$DATABASE;"
both "a high byte is ONE octet, not its UTF-8 pair" \
  "SELECT x'FF', OCTET_LENGTH(x'FF'), OCTET_LENGTH(x'C3A9') FROM RDB\$DATABASE;"
both "CAST to a number reads the DIGITS, and its 22018 spells the BYTES" \
  "SELECT CAST(x'3132' AS SMALLINT) FROM RDB\$DATABASE; SELECT CAST(x'FF' AS SMALLINT) FROM RDB\$DATABASE;"

# ---- the comparison laws ------------------------------------------------
both "0x00 pads the shorter side, and a blank is NOT the pad" \
  "SELECT 'a' FROM RDB\$DATABASE WHERE x'41' = 'A'; SELECT 'b' FROM RDB\$DATABASE WHERE x'4100' = 'A'; SELECT 'c' FROM RDB\$DATABASE WHERE x'4120' = 'A'; SELECT 'd' FROM RDB\$DATABASE WHERE x'41' = 'A ';"
both "the binary pad orders too: x'41' < 'A ', and x'41' < x'42'" \
  "SELECT 'lt' FROM RDB\$DATABASE WHERE x'41' < 'A '; SELECT 'lt2' FROM RDB\$DATABASE WHERE x'41' < x'42';"

# ---- a stored OCTETS column --------------------------------------------
mk() { cat <<'SQL'
CREATE TABLE OC (ID INTEGER, P CHAR(4) CHARACTER SET OCTETS, V VARCHAR(4) CHARACTER SET OCTETS, U VARCHAR(4));
CREATE INDEX OCP ON OC (P);
COMMIT;
INSERT INTO OC VALUES (1, x'6162', x'6162', 'ab');
INSERT INTO OC VALUES (2, x'41FF', x'41FF', 'zz');
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
both "a CHAR OCTETS column pads with 0x00 (and a high byte survives)" \
  "SELECT ID, P, V, OCTET_LENGTH(P), OCTET_LENGTH(V) FROM OC ORDER BY ID;"
both "the 0x00 pad is what TRIM strips, and 0x20 is not" \
  "SELECT OCTET_LENGTH(TRIM(TRAILING x'00' FROM P)), OCTET_LENGTH(TRIM(TRAILING x'20' FROM P)), OCTET_LENGTH(TRIM(P)) FROM OC WHERE ID = 1;"
both "TRIM over a literal: 0x20 survives, 0x00 goes, an explicit character is used as written" \
  "SELECT OCTET_LENGTH(TRIM(x'204120')), OCTET_LENGTH(TRIM(x'004100')), OCTET_LENGTH(TRIM(LEADING x'20' FROM x'204120')) FROM RDB\$DATABASE;"
both "the column compares with the 0x00 pad, from either side" \
  "SELECT 'short' FROM OC WHERE P = x'6162'; SELECT 'full' FROM OC WHERE P = x'61620000'; SELECT 'text' FROM OC WHERE P = 'ab'; SELECT 'rev' FROM OC WHERE x'61620000' = P;"
both "UPPER and LOWER are identity over OCTETS - column and literal" \
  "SELECT UPPER(P), LOWER(P), UPPER(V), UPPER(x'6162'), LOWER(x'4142') FROM OC WHERE ID = 1;"
both "LPAD and RPAD fill with 0x00" \
  "SELECT LPAD(x'41',3), RPAD(x'41',3), LPAD(P,6) FROM OC WHERE ID = 1;"

# ---- LIKE / STARTING ----------------------------------------------------
both "LIKE over a binary side has no wildcards and matches the FULL padded value" \
  "SELECT 'short' FROM OC WHERE P LIKE x'6162'; SELECT 'full' FROM OC WHERE P LIKE x'61620000'; SELECT 'pct' FROM OC WHERE P LIKE x'612525'; SELECT 'var' FROM OC WHERE V LIKE x'6162'; SELECT 'varpct' FROM OC WHERE V LIKE x'6125';"
both "NOT LIKE and a text pattern follow the same law" \
  "SELECT 'not' FROM OC WHERE P NOT LIKE x'6162' AND ID = 1; SELECT 'txt' FROM OC WHERE P LIKE 'ab';"
both "a CHAR left operand keeps its wildcards even with a binary pattern" \
  "SELECT 'lit' FROM RDB\$DATABASE WHERE 'ABC' LIKE x'4125'; SELECT 'col' FROM OC WHERE U LIKE x'6125';"
both "two binary sides: exact matches, wildcard does not" \
  "SELECT 'exact' FROM RDB\$DATABASE WHERE x'414243' LIKE x'414243'; SELECT 'pct' FROM RDB\$DATABASE WHERE x'414243' LIKE x'4125';"
# SIMILAR TO is a different matcher and DOES keep its wildcards over a binary
# operand (Re2SimilarMatcher parses its own grammar in Latin-1) - the one place
# where a binary left side behaves like text.
both "SIMILAR TO keeps its wildcards over a binary side" \
  "SELECT 'a' FROM OC WHERE P SIMILAR TO x'61252525'; SELECT 'b' FROM OC WHERE P SIMILAR TO x'6162252525'; SELECT 'c' FROM OC WHERE P SIMILAR TO 'ab___'; SELECT 'd' FROM OC WHERE U SIMILAR TO x'6125';"
both "an index on a binary column answers the same rows" \
  "SELECT ID FROM OC WHERE P = x'6162'; SELECT ID FROM OC WHERE P > x'4200'; SELECT ID FROM OC WHERE P BETWEEN x'4100' AND x'6200'; SELECT ID FROM OC WHERE P IN (x'6162', x'0000');"
both "STARTING WITH is a plain byte prefix" \
  "SELECT 'p' FROM OC WHERE P STARTING WITH x'61'; SELECT 'full' FROM OC WHERE P STARTING WITH x'61620000'; SELECT 'txt' FROM OC WHERE P STARTING WITH 'ab'; SELECT 'u' FROM OC WHERE U STARTING WITH x'61';"

# ---- the absorbing result charset --------------------------------------
both "one binary operand makes the result binary - concat, CASE, COALESCE, MIN" \
  "SELECT x'41' || 'B', 'B' || x'41', COALESCE(NULL, x'4142'), CASE WHEN 1=0 THEN 'B' ELSE x'4142' END, MIN(P), MAX(V) FROM OC WHERE ID = 1;"
bothd "and the describe says so" \
  "SELECT x'41' || 'B', COALESCE(NULL, x'4142'), P || x'FF' FROM OC;"
both "a high byte through concat / substring / replace stays ONE octet" \
  "SELECT P || x'FF', OCTET_LENGTH(P || x'FF'), OCTET_LENGTH(U || x'FF'), SUBSTRING(x'41FF43' FROM 2 FOR 2), REPLACE(x'414243', x'42', x'FF') FROM OC WHERE ID = 1;"
bothd "REPLACE's own width and charset" \
  "SELECT REPLACE(U,'a','zz'), REPLACE(x'414243', x'42', x'FF') FROM OC;"

# ---- DML, ordering, grouping -------------------------------------------
both "a hex literal in INSERT / UPDATE / WHERE round-trips" \
  "INSERT INTO OC VALUES (3, x'00FF', x'00FF', 'q'); COMMIT; UPDATE OC SET V = x'FFFE' WHERE P = x'00FF'; COMMIT; SELECT ID, P, V FROM OC ORDER BY ID;"
both "ORDER BY / DISTINCT / GROUP BY over a binary column" \
  "SELECT P FROM OC ORDER BY P; SELECT DISTINCT V FROM OC ORDER BY 1; SELECT P, COUNT(*) FROM OC GROUP BY P ORDER BY 1;"

# ---- the engine reads fc's file -----------------------------------------
eng_q="SET LIST ON; SELECT ID, P, V, OCTET_LENGTH(P) AS OL FROM OC ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's OCTETS table (0x00 padding in fc's own layout)" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
# The two recorded boundaries, asserted the way a client meets them - the
# statement RUNS and the refusal comes back (execute_immediate through the C
# helper answers neither shape, so isql is the honest probe here).
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    case "$r" in
        *"Statement failed"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     fc: $r"; fail=1 ;;
    esac
}
refuses "a LIKE pattern that is not a LITERAL against a binary side refuses" \
  "SELECT ID FROM OC WHERE P LIKE 'a' || '';"
refuses "CAST … CHARACTER SET refuses" \
  "SELECT CAST(P AS VARCHAR(6) CHARACTER SET OCTETS) FROM OC;"
refuses "a hex literal as a column DEFAULT refuses (the DDL parser's own slice)" \
  "CREATE TABLE HD (ID INTEGER, P CHAR(2) CHARACTER SET OCTETS DEFAULT x'FFFE');"
refuses "a hex literal inside a PSQL body refuses (the BLR compiler's own slice)" \
  "EXECUTE BLOCK RETURNS (R CHAR(2) CHARACTER SET OCTETS) AS BEGIN R = x'4142'; SUSPEND; END"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
