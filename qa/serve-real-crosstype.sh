#!/bin/bash
# Cross-type procedure inputs, the engine's CVT: a TEXT argument into an
# INTEGER parameter (leading/trailing spaces trimmed, anything left over
# raises 22018 "conversion error from string"), and an INTEGER argument
# into a text parameter (rendered decimal, then the parameter's width and
# CHAR-padding, an over-long value a 22018 conversion error too). The
# same conversion runs whether the call is `EXECUTE PROCEDURE` or a
# selectable `SELECT ... FROM p(arg)`.
#
#   qa/serve-real-crosstype.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4892}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-crosstype-crab.fdb"; B="$D/fc-crosstype-engine.fdb"
LOG="/tmp/fc-serve-crosstype-$PORT.log"
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

cat > "$D/ct-setup.sql" <<'SQL'
SET TERM ^;
CREATE PROCEDURE PI (A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A + 1; SUSPEND; END^
CREATE PROCEDURE PS (A VARCHAR(10)) RETURNS (R VARCHAR(20)) AS BEGIN R = A || '!'; SUSPEND; END^
CREATE PROCEDURE PSC (A CHAR(4)) RETURNS (R INTEGER) AS BEGIN R = CHAR_LENGTH(A); SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/ct-setup.sql" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/ct-setup.sql" >/dev/null 2>&1
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/ct.sql" 2>&1 | norm; }

cat > "$D/ct.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PI('41');
SELECT R FROM PI(' 41 ');
SELECT R FROM PI('-7');
SELECT R FROM PS(5);
SELECT R FROM PS(12345);
SELECT R FROM PSC(7);
EXECUTE PROCEDURE PI('100');
EXECUTE PROCEDURE PS(99);
SQL
check "text->INTEGER and INTEGER->text, via SELECT and EXECUTE PROCEDURE" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

cat > "$D/ct.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PI('41abc');
SELECT R FROM PI('abc');
SELECT R FROM PS(123456789012);
SQL
check "the 22018 conversion errors (bad text, over-long integer)" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
