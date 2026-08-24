#!/bin/bash
# The two-argument statistical aggregates - linear CORRELATION, COVARIANCE
# and the linear-REGRESSION family: CORR, COVAR_POP, COVAR_SAMP, and
# REGR_SLOPE / REGR_INTERCEPT / REGR_COUNT / REGR_R2 / REGR_AVGX / REGR_AVGY
# / REGR_SXX / REGR_SYY / REGR_SXY. Each folds n and the five paired sums
# (Sx / Sxx / Sy / Syy / Sxy) over the rows where BOTH arguments are
# non-null - the FIRST SQL argument is Y, the SECOND X, per the standard and
# the engine's CorrAggNode - then answers a DOUBLE (a BIGINT for REGR_COUNT)
# from the engine's own closed formula, folded in f64 in the SAME operation
# order so the DOUBLE bits match to the last place.
#
# They CAN be NULL at run time (an empty or single-row group, a zero
# variance) yet the engine DESCRIBES them NOT nullable, like COUNT and
# VAR/STDDEV - so a NULL result travels on a not-nullable column and renders
# as 0 (REGR_COUNT is the pair count, 0 over an empty group). fc follows both
# the value and that describe quirk.
#
# Covered (fc vs the live engine): the twelve values over DOUBLE, INTEGER and
# NUMERIC operands, whole-table and GROUP BY; a NULL-operand row dropped from
# the fold; a degenerate (single-row) group; the FILTER (WHERE ...) form
# (which drops a non-matching row from both arguments); and the SQLDA
# describe (DOUBLE / BIGINT, NOT nullable) byte for byte.
#
# Boundaries (recorded): a DECFLOAT / INT128 operand (the engine folds it in
# the decimal128 domain; fc has no decimal128 aggregate and refuses); these
# folds inside an EXPRESSION - CASE / COALESCE / a comparison / a scalar
# subquery / a window OVER clause - refuse, the same top-level-select-item
# limit VAR / STDDEV carry (a pre-existing shared boundary).
#
#   qa/serve-real-statagg2.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4947}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-sa2-crab.fdb"; B="$D/fc-sa2-engine.fdb"
LOG="/tmp/fc-serve-sa2-$PORT.log"
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

SET='CREATE TABLE T(X DOUBLE PRECISION, Y DOUBLE PRECISION, I INTEGER, N NUMERIC(9,2), G INTEGER);
INSERT INTO T VALUES (1, 2, 1, 2.50, 1);
INSERT INTO T VALUES (2, 4, 2, 4.00, 1);
INSERT INTO T VALUES (3, 5, 3, 5.50, 1);
INSERT INTO T VALUES (4, 4, 4, 4.00, 2);
INSERT INTO T VALUES (5, 5, 5, 5.00, 2);
INSERT INTO T VALUES (6, NULL, 6, NULL, 2);
INSERT INTO T VALUES (9, 9, 9, 9.00, 3);
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

cat > "$D/v.sql" <<'SQL'
SET LIST ON;
SELECT CORR(Y,X) A, COVAR_POP(Y,X) B, COVAR_SAMP(Y,X) C, REGR_COUNT(Y,X) D FROM T;
SELECT REGR_SLOPE(Y,X) A, REGR_INTERCEPT(Y,X) B, REGR_R2(Y,X) C, REGR_AVGX(Y,X) D, REGR_AVGY(Y,X) E FROM T;
SELECT REGR_SXX(Y,X) A, REGR_SYY(Y,X) B, REGR_SXY(Y,X) C FROM T;
SQL
vof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/v.sql" 2>&1 | norm; }
check "the twelve values over DOUBLE columns (a NULL-Y row dropped)" \
    "$(vof "127.0.0.1/$PORT:$A")" "$(vof "127.0.0.1/$REAL:$B")"

cat > "$D/m.sql" <<'SQL'
SET LIST ON;
SELECT CORR(N,I) A, REGR_SLOPE(N,I) B, COVAR_POP(N,I) C, REGR_SXX(N,I) D, REGR_AVGX(I,I) E FROM T;
SQL
mof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/m.sql" 2>&1 | norm; }
check "over INTEGER and NUMERIC operands" \
    "$(mof "127.0.0.1/$PORT:$A")" "$(mof "127.0.0.1/$REAL:$B")"

# A scaled-NUMERIC operand converts to double the engine's way (raw / 100.0,
# a single division), NOT raw * 0.01 - values chosen to expose the 1-ULP
# difference the two conversions produce; and REGR_INTERCEPT's avgY - slope*
# avgX is fused (a single-rounding multiply-add) to the last bit.
SETM='CREATE TABLE M(Y NUMERIC(9,2), X NUMERIC(9,2), G INTEGER);
INSERT INTO M VALUES (0.35, 0.41, 1);
INSERT INTO M VALUES (0.70, 0.57, 1);
INSERT INTO M VALUES (7.00, 2.33, 2);
INSERT INTO M VALUES (11.77, 4.90, 2);
INSERT INTO M VALUES (3.30, 9.90, 2);
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETM" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETM" >/dev/null 2>&1
cat > "$D/mm.sql" <<'SQL'
SET LIST ON;
SELECT REGR_AVGY(Y,X) A, CORR(Y,X) B, REGR_SXX(Y,X) C, COVAR_POP(Y,X) D, REGR_SLOPE(Y,X) E, REGR_INTERCEPT(Y,X) F FROM M;
SELECT G, REGR_INTERCEPT(Y,X) I, CORR(Y,X) C FROM M GROUP BY G ORDER BY G;
SQL
mmof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/mm.sql" 2>&1 | norm; }
check "scaled-NUMERIC conversion (raw/100) and fused REGR_INTERCEPT, last-bit" \
    "$(mmof "127.0.0.1/$PORT:$A")" "$(mmof "127.0.0.1/$REAL:$B")"

cat > "$D/g.sql" <<'SQL'
SET LIST ON;
SELECT G, CORR(Y,X) C, REGR_SLOPE(Y,X) S, REGR_INTERCEPT(Y,X) B, REGR_COUNT(Y,X) N FROM T GROUP BY G ORDER BY G;
SQL
gof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/g.sql" 2>&1 | norm; }
check "GROUP BY (a NULL-operand row and a single-row group G=3)" \
    "$(gof "127.0.0.1/$PORT:$A")" "$(gof "127.0.0.1/$REAL:$B")"

cat > "$D/f.sql" <<'SQL'
SET LIST ON;
SELECT CORR(Y,X) FILTER (WHERE G=1) A, REGR_COUNT(Y,X) FILTER (WHERE G=1) B,
       REGR_SLOPE(N,I) FILTER (WHERE G IN (1,2)) C FROM T;
SQL
fof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/f.sql" 2>&1 | norm; }
check "the FILTER (WHERE ...) form drops a non-matching row from both args" \
    "$(fof "127.0.0.1/$PORT:$A")" "$(fof "127.0.0.1/$REAL:$B")"

cat > "$D/e.sql" <<'SQL'
SET LIST ON;
SELECT CORR(Y,X) C, REGR_SLOPE(Y,X) S, COVAR_SAMP(Y,X) V, REGR_COUNT(Y,X) N FROM T WHERE X=99;
SQL
eof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/e.sql" 2>&1 | norm; }
check "an empty set (a NULL result on a not-nullable column, REGR_COUNT 0)" \
    "$(eof "127.0.0.1/$PORT:$A")" "$(eof "127.0.0.1/$REAL:$B")"

cat > "$D/d.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT CORR(Y,X), COVAR_POP(Y,X), COVAR_SAMP(Y,X), REGR_COUNT(Y,X), REGR_SLOPE(Y,X) FROM T;
SELECT REGR_R2(Y,X), REGR_AVGX(Y,X), REGR_SXX(Y,X) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/d.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe (DOUBLE / BIGINT, NOT nullable) matches" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
