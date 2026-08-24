#!/bin/bash
# ASCII_VAL(s) in the SysFn scalar machinery: the SMALLINT code of the
# first character of the argument (a byte-carrier char's code IS its
# byte), 0 for an empty string. Joins MOD / ABS / SIGN.
#
# Covered (fc vs the live engine): the value over literals (letters,
# digit, empty) and a column, and the describe (SMALLINT).
#
# Boundary (recorded): ASCII_VAL of a genuine multibyte (UTF8) first
# character takes its code point where the engine takes the first byte -
# single-byte / NONE / ASCII agree. (ASCII_CHAR is a follow-up: its
# CHAR(1) NONE result needs fc's byte-carrier value-width handling for a
# byte 128..255, a separate charset slice.)
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

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
