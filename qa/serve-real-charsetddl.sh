#!/bin/bash
# CREATE TABLE with CHARACTER SET / NCHAR columns - the charsets that fell to
# Plan::Refused. Probed: the catalog (RDB$FIELD_TYPE, RDB$FIELD_LENGTH =
# char_len * bytes-per-char, RDB$CHARACTER_LENGTH = the char count,
# RDB$CHARACTER_SET_ID, RDB$COLLATION_ID 0, RDB$FIELD_SUB_TYPE 0), the
# describe, and the RECORD LAYOUT - values round-trip through fc, a multibyte
# UTF8 value's CHAR_LENGTH/OCTET_LENGTH are right, and the ENGINE reads fc's
# table byte-identically. gfix validates it. NCHAR / NATIONAL CHARACTER map to
# ISO8859_1.
# Non-default COLLATE (the built-in UTF8 family) is supported; RDB$COLLATION_ID
# is written on both the field and relation-field rows. Boundary (recorded): a
# language collation this server does not carry refuses (a later slice).
#
#   qa/serve-real-charsetddl.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4893}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-charsetddl-crab.fdb"
B="$D/fc-charsetddl-engine.fdb"
LOG="/tmp/fc-serve-charsetddl-$PORT.log"
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
mk() { cat <<'SQL'
CREATE TABLE CT (NC NCHAR(3), NCV NCHAR VARYING(4), CW CHAR(4) CHARACTER SET WIN1252, CI CHAR(4) CHARACTER SET ISO8859_1, VU VARCHAR(5) CHARACTER SET UTF8, VN VARCHAR(3) CHARACTER SET NONE, CA CHAR(2) CHARACTER SET ASCII, VW VARCHAR(6) CHARACTER SET WIN1251, CU VARCHAR(5) CHARACTER SET UTF8 COLLATE UNICODE, CB CHAR(4) CHARACTER SET UTF8 COLLATE UCS_BASIC);
COMMIT;
INSERT INTO CT VALUES ('abc', 'wx', 'qrst', 'lm', 'hello', 'yz', 'ok', 'zzz', 'coll', 'basi');
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
cat_q="SET LIST ON; SELECT rf.RDB\$FIELD_NAME AS C, f.RDB\$FIELD_TYPE AS FT, f.RDB\$FIELD_LENGTH AS LEN, f.RDB\$CHARACTER_LENGTH AS CLEN, f.RDB\$CHARACTER_SET_ID AS CS, f.RDB\$COLLATION_ID AS COLL, rf.RDB\$COLLATION_ID AS RFCOLL, f.RDB\$FIELD_SUB_TYPE AS SUB FROM RDB\$RELATION_FIELDS rf JOIN RDB\$FIELDS f ON f.RDB\$FIELD_NAME = rf.RDB\$FIELD_SOURCE WHERE rf.RDB\$RELATION_NAME = 'CT' ORDER BY rf.RDB\$FIELD_POSITION;"
e=$(printf '%s\n' "$cat_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(printf '%s\n' "$cat_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "the catalog (type / byte length / char length / charset / collation / sub_type)" "$c" "$e"
desc_q="SET SQLDA_DISPLAY ON; SELECT NC, NCV, CW, CI, VU, VN, CA, VW, CU, CB FROM CT;"
e=$(printf '%s\n' "$desc_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep sqltype | norm)
c=$(printf '%s\n' "$desc_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep sqltype | norm)
check "the describe (each column's charset and byte len)" "$c" "$e"
row_q="SELECT NC, NCV, CW, CI, VU, VN, CA, VW, CU, CB FROM CT;"
e=$(printf '%s\n' "$row_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(printf '%s\n' "$row_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "ASCII-range values round-trip through fc" "$c" "$e"
# multibyte UTF8: fc creates a UTF8 table and a UTF8 client inserts multibyte
# content; CHAR_LENGTH counts characters, OCTET_LENGTH counts bytes.
printf "%s\n" "CREATE TABLE U (ID INTEGER, S VARCHAR(5) CHARACTER SET UTF8); COMMIT;" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
printf "%s\n" "CREATE TABLE U (ID INTEGER, S VARCHAR(5) CHARACTER SET UTF8); COMMIT;" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
printf 'INSERT INTO U VALUES (1, %s); INSERT INTO U VALUES (2, %s); COMMIT;\n' "'caf\xc3\xa9'" "'\xc3\xa9\xc3\xa8\xc3\xaa'" > "$D/u8ins.sql"
"$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/u8ins.sql" >/dev/null 2>&1
"$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/u8ins.sql" >/dev/null 2>&1
u8_q="SET LIST ON; SELECT ID, CHAR_LENGTH(S) AS CL, OCTET_LENGTH(S) AS OL FROM U ORDER BY ID;"
e=$(printf '%s\n' "$u8_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(printf '%s\n' "$u8_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "a multibyte UTF8 value stored by fc has the right CHAR_LENGTH / OCTET_LENGTH" "$c" "$e"
# the ENGINE reads fc's tables (catalog + the multibyte content in fc's layout)
eng_q="SET LIST ON; SELECT ID, CHAR_LENGTH(S) AS CL, OCTET_LENGTH(S) AS OL, S FROM U ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's UTF8 table (multibyte content in fc's own layout)" "$c" "$e"
# Boundary: a collation this server does not carry (a language collation)
# refuses; the built-in UTF8 family (tested above) is supported.
cb=$("$D/sqlerr" "127.0.0.1/$PORT:$A" "CREATE TABLE C2 (X VARCHAR(5) CHARACTER SET ISO8859_1 COLLATE DE_DE)" 2>&1 | norm)
ran=$((ran + 1))
if [ "${cb#*gds}" != "$cb" ]; then echo "OK   boundary: a language collation (DE_DE) refuses; the UTF8 family is in"
else echo "DIFF boundary MOVED: unknown COLLATE"; echo "     fc: $cb"; fail=1; fi
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
