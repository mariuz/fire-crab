#!/bin/bash
# The NTILE(n) window function: the ordered partition split into n buckets
# as equally as it divides (the first `size % n` buckets get one extra
# row), each row answering its 1-based bucket number. Joins fc's existing
# ranking machinery (ROW_NUMBER / RANK / DENSE_RANK); an INT64 result
# named NTILE, the engine's describe. Both servers run the same queries
# and the rows are compared.
#
# Boundary (recorded): an expression bucket count (`NTILE(:n)`) is a
# later slice - the count is a positive integer literal here.
#
#   qa/serve-real-ntile.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4890}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ntile-crab.fdb"; B="$D/fc-ntile-engine.fdb"
LOG="/tmp/fc-serve-ntile-$PORT.log"
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

for db in "127.0.0.1/$REAL:$B" "127.0.0.1/$PORT:$A"; do
    "$ISQL" -q -user "$U" -pas "$P" "$db" <<'EOF' >/dev/null 2>&1
CREATE TABLE T (ID INTEGER, G INTEGER);
INSERT INTO T VALUES (1,10); INSERT INTO T VALUES (2,10); INSERT INTO T VALUES (3,10);
INSERT INTO T VALUES (4,20); INSERT INTO T VALUES (5,20); INSERT INTO T VALUES (6,20); INSERT INTO T VALUES (7,20);
COMMIT;
EOF
done
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/nt.sql" 2>&1 | norm; }

cat > "$D/nt.sql" <<'SQL'
SET LIST ON;
SELECT ID, NTILE(2) OVER (ORDER BY ID) N FROM T ORDER BY ID;
SELECT ID, NTILE(3) OVER (ORDER BY ID) N FROM T ORDER BY ID;
SELECT ID, NTILE(4) OVER (ORDER BY ID) N FROM T ORDER BY ID;
SELECT ID, NTILE(1) OVER (ORDER BY ID) N FROM T ORDER BY ID;
SELECT ID, NTILE(10) OVER (ORDER BY ID) N FROM T ORDER BY ID;
SELECT ID, G, NTILE(2) OVER (PARTITION BY G ORDER BY ID) N FROM T ORDER BY ID;
SQL
check "NTILE(n) buckets an ordered partition, alone and PARTITIONed" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the describe: INT64, the column named NTILE
cat > "$D/nt.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT NTILE(2) OVER (ORDER BY ID) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/nt.sql" 2>&1 | grep -iE "sqltype|name:" | norm; }
check "NTILE describe (INT64, named NTILE)" "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
