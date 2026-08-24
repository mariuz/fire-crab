#!/bin/bash
# The bitwise built-in functions BIN_AND / BIN_OR / BIN_XOR (variadic,
# 2+ operands) / BIN_NOT (unary) / BIN_SHL / BIN_SHR (arithmetic, sign-
# preserving shifts) - integer in, integer out. They join fc's SysFn
# machinery beside MOD / ABS / SIGN: each operand is rounded to an integer
# and the fold is Rust's own i64 &/|/^/!/<<(>>). The result TYPE matches the
# engine: BIN_AND/OR/XOR/NOT take the WIDEST operand's integer type (never
# below INTEGER; a BIGINT operand widens the result), and BIN_SHL / BIN_SHR
# always type BIGINT.
#
# Covered (fc vs the live engine): the values over literals, columns
# (SMALLINT/INTEGER/BIGINT) and a NULL row (NULL propagates); a variadic
# AND; a negative operand and a sign-preserving right shift; the function in
# a WHERE predicate; a nested call; and the SQLDA describe (sqltype/len) for
# each result type - INTEGER vs BIGINT byte for byte.
#
# Boundaries (recorded): a text or a SCALED-numeric operand refuses on both,
# fc generically where the engine names "must be integral types or
# NUMERIC/DECIMAL without scale" (a NUMERIC(p,0) operand fc also refuses, the
# engine accepts); these are the query surface (select list / WHERE) - a
# bitwise call inside a PSQL BODY refuses at CREATE (the engine compiles it).
#
#   qa/serve-real-bitwise.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4947}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-bitwise-crab.fdb"; B="$D/fc-bitwise-engine.fdb"
LOG="/tmp/fc-serve-bitwise-$PORT.log"
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

SET='CREATE TABLE T(ID INTEGER, S SMALLINT, I INTEGER, BG BIGINT);
INSERT INTO T VALUES (1, 6, 12, 5000000000);
INSERT INTO T VALUES (2, 3, 7, 3);
INSERT INTO T VALUES (3, 0, NULL, 8);
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

cat > "$D/v.sql" <<'SQL'
SET LIST ON;
SELECT BIN_AND(12,10) A, BIN_OR(12,10) O, BIN_XOR(12,10) X, BIN_NOT(0) N FROM RDB$DATABASE;
SELECT BIN_SHL(1,4) SL, BIN_SHR(256,3) SR, BIN_SHR(-8,1) SRN FROM RDB$DATABASE;
SELECT BIN_AND(15,12,10) VARIADIC, BIN_AND(5000000000,3) BIG FROM RDB$DATABASE;
SELECT BIN_AND(-1,255) NEG, BIN_XOR(BIN_AND(12,10),BIN_OR(1,2)) NESTED FROM RDB$DATABASE;
SELECT BIN_OR(NULL,5) NUL FROM RDB$DATABASE;
SQL
vof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/v.sql" 2>&1 | norm; }
check "bitwise values (literals, variadic, bigint, negative, nested, NULL)" \
    "$(vof "127.0.0.1/$PORT:$A")" "$(vof "127.0.0.1/$REAL:$B")"

cat > "$D/c.sql" <<'SQL'
SET LIST ON;
SELECT ID, BIN_AND(I,6) A, BIN_OR(I,1) O, BIN_NOT(I) N, BIN_SHL(BG,1) SL FROM T ORDER BY ID;
SELECT ID FROM T WHERE BIN_AND(I,4)=4 ORDER BY ID;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/c.sql" 2>&1 | norm; }
check "bitwise over columns (with a NULL row) and in a WHERE predicate" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

cat > "$D/d.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT BIN_AND(12,10), BIN_SHL(1,4), BIN_NOT(5), BIN_AND(5000000000,3) FROM RDB$DATABASE;
SELECT BIN_AND(S,I), BIN_AND(I,BG), BIN_NOT(S), BIN_SHR(I,1) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/d.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe (INTEGER vs BIGINT) matches - literals and columns" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# INT128 widening: an operand past i64 (a wide literal, or i128-producing
# arithmetic) makes the result INT128 - the fold and the shifts keep the
# full 128-bit magnitude, and the describe announces INT128 (len 16), not
# a truncated BIGINT.
cat > "$D/w.sql" <<'SQL'
SET LIST ON;
SELECT BIN_AND(9999999999999999999, 1) A, BIN_AND(10000000000000000000, 15) Z FROM RDB$DATABASE;
SELECT BIN_OR(4000000000 * 3, 1) O, BIN_SHL(9999999999999999999, 1) SL, BIN_SHR(20000000000000000000, 1) SR FROM RDB$DATABASE;
SQL
wof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/w.sql" 2>&1 | norm; }
check "INT128 widening: wide operands keep full magnitude (fold + shift)" \
    "$(wof "127.0.0.1/$PORT:$A")" "$(wof "127.0.0.1/$REAL:$B")"
cat > "$D/wd.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT BIN_AND(9999999999999999999, 1), BIN_SHL(9999999999999999999, 1), BIN_OR(4000000000 * 3, 1) FROM RDB$DATABASE;
SQL
wdof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/wd.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the INT128 result describes as INT128 (len 16), not BIGINT" \
    "$(wdof "127.0.0.1/$PORT:$A")" "$(wdof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
