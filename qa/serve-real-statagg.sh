#!/bin/bash
# The statistical aggregates VAR_POP / VAR_SAMP / STDDEV_POP / STDDEV_SAMP:
# a DOUBLE fold over the non-null values, the naive sum-of-squares the
# engine uses (Sxx - Sx*Sx/n over n or n-1) so the DOUBLE bits match. They
# are NOT nullable and NEVER NULL - an empty, single-row or all-NULL group
# is 0, not NULL (probed against FB6: the describe carries no Nullable
# flag, like COUNT; VAR_SAMP over one row and any fold over none are 0, not
# a divide by zero). Sources: an INTEGER column, a NUMERIC(9,2) column
# (folded at its scale) and an arbitrary expression; whole-table and
# GROUP BY. Both servers run the same queries and the rows are compared.
#
# Boundaries (recorded): the OVER (window) form, a HAVING comparison, a
# scalar subquery and DISTINCT all REFUSE here (the engine answers them) -
# these folds are top-level select items only for now. A DOUBLE-column
# source is untested because fc cannot yet INSERT into a DOUBLE column
# (a separate DML gap), so the describe accepts it but no data reaches it.
#
#   qa/serve-real-statagg.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4895}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-statagg-crab.fdb"; B="$D/fc-statagg-engine.fdb"
LOG="/tmp/fc-serve-statagg-$PORT.log"
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
CREATE TABLE T (G INTEGER, X INTEGER, N NUMERIC(9,2));
INSERT INTO T (G,X,N) VALUES (1,10,10.00);
INSERT INTO T (G,X,N) VALUES (1,20,20.00);
INSERT INTO T (G,X,N) VALUES (1,30,30.50);
INSERT INTO T (G,X,N) VALUES (2,7,7.00);
INSERT INTO T (G,X,N) VALUES (2,NULL,NULL);
COMMIT;
EOF
done
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sa.sql" 2>&1 | norm; }

cat > "$D/sa.sql" <<'SQL'
SET LIST ON;
SELECT VAR_POP(X) VP, VAR_SAMP(X) VS, STDDEV_POP(X) SP, STDDEV_SAMP(X) SS FROM T;
SELECT VAR_POP(N) VPN, VAR_SAMP(N) VSN, STDDEV_POP(N) SPN, STDDEV_SAMP(N) SSN FROM T;
SELECT G, VAR_POP(X) VP, VAR_SAMP(X) VS, STDDEV_POP(X) SP, STDDEV_SAMP(X) SS FROM T GROUP BY G ORDER BY G;
SELECT G, VAR_POP(N) VPN, STDDEV_SAMP(N) SSN FROM T GROUP BY G ORDER BY G;
SELECT VAR_POP(X+N) VE, STDDEV_POP(X*2) SE FROM T;
SQL
check "VAR/STDDEV over INTEGER, NUMERIC and an expression, whole-table and grouped" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the never-NULL edges: a single-value group, an all-NULL group, an empty set
cat > "$D/sa.sql" <<'SQL'
SET LIST ON;
SELECT VAR_SAMP(X) V FROM T WHERE G=2;
SELECT STDDEV_SAMP(X) V FROM T WHERE X=7;
SELECT VAR_POP(X) V FROM T WHERE G=99;
SELECT VAR_SAMP(X) V FROM T WHERE G=99;
SELECT VAR_POP(X) V, VAR_SAMP(X) W FROM T WHERE X IS NULL;
SQL
check "the never-NULL edges: single-row, all-NULL and empty are 0, not NULL" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the describe: DOUBLE, named by the function, NOT nullable (no Nullable flag)
cat > "$D/sa.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT VAR_POP(X), STDDEV_SAMP(N) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sa.sql" 2>&1 | grep -iE "sqltype|name:" | norm; }
check "VAR/STDDEV describe (DOUBLE, function-named, not nullable)" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
