#!/bin/bash
# CHAR travels as CHAR. Until this slice every CHAR column and every
# fixed-text expression described as VARYING (448) - a client saw CHAR(5)
# as VARCHAR(5). Now a CHAR column, a text literal, CAST AS CHAR, UPPER /
# LOWER of a CHAR, a CASE / COALESCE of CHARs describe 452 (TEXT) at the
# engine's width (a UTF8 CHAR(3) is 12 bytes), and the row carries the
# bytes space-padded, no length word - in the FORM THE CLIENT DECLARED in
# its blr (blr_text vs blr_varying, at the client's declared length),
# which is how the engine serves a CHAR fetched as VARCHAR and back; TRIM,
# ||, SUBSTRING and a VARCHAR stay 448. Probed laws; isql with SQLDA
# display on both servers, describe and values compared line by line.
#
#   qa/serve-real-charform.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4881}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-charform-crab.fdb"
B="$D/fc-charform-engine.fdb"
LOG="/tmp/fc-serve-charform-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, C CHAR(5), V VARCHAR(5), U CHAR(3) CHARACTER SET UTF8, N CHAR(4) CHARACTER SET NONE);
COMMIT;
INSERT INTO T VALUES (1, 'ab', 'cd', 'xy', 'n');
INSERT INTO T VALUES (2, 'abcde', 'vwxyz', 'abc', 'none');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL);
COMMIT;
EOF
    chmod 666 "$1"
}
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
run() { # <conn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
      | grep -v '^$' | grep -v '^  : table' | sed 's/ *$//' | tr '\n' '|'
}
while IFS= read -r q; do
    [ -z "$q" ] && continue
    e=$(run "127.0.0.1/$REAL:$B" "$q"); c=$(run "127.0.0.1/$PORT:$A" "$q")
    check "$q" "$c" "$e"
done <<'SQL'
SELECT ID, C, V, U, N FROM T ORDER BY ID;
SELECT 'lit', CAST(V AS CHAR(4)), CAST(C AS VARCHAR(4)) FROM T WHERE ID = 1;
SELECT UPPER(C), LOWER(C), C || 'z', TRIM(C), SUBSTRING(C FROM 1 FOR 2) FROM T ORDER BY ID;
SELECT CASE WHEN C = 'ab' THEN 'a' ELSE 'bcd' END, COALESCE(C, 'q'), IIF(ID = 1, C, 'zz') FROM T ORDER BY ID;
SELECT C FROM T WHERE C = 'ab';
SELECT COUNT(*) FROM T WHERE UPPER(C) = 'AB';
SELECT U, UPPER(U), U || '!' FROM T ORDER BY ID;
SELECT N, UPPER(N) FROM T ORDER BY ID;
SQL
echo "ran $ran checks"
exit $fail
