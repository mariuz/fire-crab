#!/bin/bash
# CAST(<blob> AS VARCHAR/CHAR/INTEGER) - a blob READ inside the expression
# engine. The evaluator carries no database, so the connection loop arms a
# per-op image (BLOB_CTX) and `Expr::BlobText` materialises the column's
# blob at evaluation: a text or binary blob casts to its bytes; the text
# truncation vector when it does not fit; a user sub_type has no filter
# to text (isc_nofilter); CAST to a number converts the text (the
# conversion error names it); the cast works in the WHERE, under UPPER /
# LIKE / ||, in ORDER BY, and only decodes the blob column when the
# statement reads it. Both databases are engine-built; every statement
# runs through isql on both servers and the outputs are compared line by
# line (SQLDA display included, so the describe is compared too).
#
# Recorded boundary: CAST(x AS CHAR(n)) describes 448 (VARYING) on fc for
# ANY operand (the engine: 452) - the fixed-text wire form is a later
# slice, so the CHAR case is not in this gate.
#
#   qa/serve-real-blobcast.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4873}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-blobcast-crab.fdb"
B="$D/fc-blobcast-engine.fdb"
LOG="/tmp/fc-serve-blobcast-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE CB (ID INTEGER, T BLOB SUB_TYPE TEXT, Z BLOB SUB_TYPE 0, N BLOB SUB_TYPE -5, U BLOB SUB_TYPE TEXT CHARACTER SET UTF8, K INTEGER);
COMMIT;
INSERT INTO CB VALUES (1, 'hello world', 'bin', _octets 'n5', 'abc', 42);
INSERT INTO CB VALUES (2, '12345', NULL, NULL, NULL, 7);
INSERT INTO CB VALUES (3, NULL, 'zzz', NULL, 'xy', 1);
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
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -v '^$' | grep -v '^  :' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'
}
while IFS= read -r q; do
    [ -z "$q" ] && continue
    e=$(run "127.0.0.1/$REAL:$B" "$q"); c=$(run "127.0.0.1/$PORT:$A" "$q")
    check "$q" "$c" "$e"
done <<'SQL'
SELECT ID, CAST(T AS VARCHAR(20)) FROM CB ORDER BY ID;
SELECT CAST(T AS VARCHAR(5)) FROM CB WHERE ID = 1;
SELECT CAST(T AS VARCHAR(5)) FROM CB WHERE ID = 2;
SELECT CAST(Z AS VARCHAR(10)) FROM CB ORDER BY ID;
SELECT CAST(N AS VARCHAR(10)) FROM CB WHERE ID = 1;
SELECT CAST(N AS VARCHAR(10)) FROM CB WHERE ID = 2;
SELECT CAST(U AS VARCHAR(3)) FROM CB ORDER BY ID;
SELECT CAST(T AS INTEGER) FROM CB WHERE ID = 2;
SELECT CAST(T AS INTEGER) FROM CB WHERE ID = 1;
SELECT CAST(T AS INTEGER) + K FROM CB WHERE ID = 2;
SELECT ID FROM CB WHERE CAST(T AS VARCHAR(20)) = 'hello world';
SELECT ID FROM CB WHERE CAST(T AS VARCHAR(20)) LIKE 'hello%';
SELECT ID FROM CB WHERE UPPER(CAST(T AS VARCHAR(20))) = 'HELLO WORLD';
SELECT ID FROM CB WHERE CAST(T AS VARCHAR(20)) IS NULL;
SELECT CAST(T AS VARCHAR(20)) || '!' FROM CB WHERE ID = 1;
SELECT UPPER(CAST(T AS VARCHAR(20))) FROM CB ORDER BY ID;
SELECT CHAR_LENGTH(CAST(T AS VARCHAR(20))) FROM CB ORDER BY ID;
SELECT ID FROM CB ORDER BY CAST(T AS VARCHAR(20));
SELECT COUNT(*) FROM CB WHERE CAST(Z AS VARCHAR(10)) = 'bin';
SELECT ID, K FROM CB WHERE CAST(T AS VARCHAR(20)) = 'hello world' OR K = 1 ORDER BY ID;
SELECT COALESCE(CAST(T AS VARCHAR(20)), 'none') FROM CB ORDER BY ID;
SQL
echo "ran $ran checks"
exit $fail
