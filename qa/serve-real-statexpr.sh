#!/bin/bash
# AGGREGATES IN EXPRESSIONS - the statistical/ordered-set family
# (VAR_*/STDDEV_*/CORR/COVAR_*/REGR_*, PERCENTILE_CONT/DISC) and
# SUM/AVG-over-expressions, in every position the engine serves them:
# select-list arithmetic and wrappers (ROUND/CAST/COALESCE/CASE/unary
# minus/NULLIF), HAVING (bare and expression forms), ORDER BY (bare
# and expression), GROUP BY per group. fire-crab used to refuse ALL of
# it (the family folded as bare top-level items only).
#
# The measured engine laws this gate pins:
#   - any arithmetic over the VAR/STDDEV/CORR family is DOUBLE,
#     described NOT NULLABLE yet NULL-capable on the wire (isql renders
#     such a NULL 0.000000000000000; COALESCE exposes the real NULL);
#     PERCENTILE_CONT stays nullable through expressions; SUM/AVG stay
#     exact (INT64:-2 * INT64:-2 folds INT128:-4)
#   - VAR_SAMP/STDDEV_SAMP of a SINGLE row are NULL, VAR_POP/STDDEV_POP
#     of one row are 0.0; the whole family is NULL over an empty set
#     (fc's fold answered 0.0 everywhere - the never-NULL 0.0 matched
#     every bare render and COALESCE(VAR_SAMP(..), -1) exposed it)
#   - ROUND over a DOUBLE aggregate stays DOUBLE; CAST types normally
#   - a CASE of CHAR literals over a family condition describes TEXT at
#     the literal length (a stale placeholder announced len 8)
#   - HAVING compares the family through the numeric alignment whatever
#     the source column's type; NULL fails the predicate
#   - ORDER BY an aggregate sorts groups with NULL LAST in ASC and DESC
#
# Boundaries (recorded): LIST in an expression (a computed-blob concat)
# refuses; DISTINCT inside the family refuses (engine: -104 Token
# unknown); an aggregate in WHERE refuses generically where the engine
# spells "Cannot use an aggregate..."; NTILE/window functions have no
# expression leaf (window-in-expression refuses); non-aggregate ORDER
# BY expressions on the grouped path keep refusing.
#
#   qa/serve-real-statexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4975}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-sx-crab.fdb"; B="$D/fc-sx-engine.fdb"
LOG="/tmp/fc-serve-sx-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE S (G INTEGER, N NUMERIC(9,2), B BIGINT, T VARCHAR(10));
INSERT INTO S VALUES (1, 1.50, 10, 'a');
INSERT INTO S VALUES (1, 2.25, 20, 'b');
INSERT INTO S VALUES (1, 4.80, 31, NULL);
INSERT INTO S VALUES (2, 7.05, 44, 'c');
INSERT INTO S VALUES (2, 9.10, 58, 'd');
INSERT INTO S VALUES (3, 3.00, NULL, 'e');
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

# --- select-list expressions over the family ---
cat > "$D/sx1.sql" <<'SQL'
SET LIST ON;
SELECT STDDEV_SAMP(N) * 2 X1 FROM S;
SELECT ROUND(VAR_POP(N), 2) X2 FROM S;
SELECT CAST(STDDEV_POP(N) AS NUMERIC(9,3)) X3 FROM S;
SELECT VAR_SAMP(N) + VAR_POP(N) X4 FROM S;
SELECT CORR(N, B) * 100 X5 FROM S;
SELECT COALESCE(VAR_SAMP(N), 0) + COUNT(*) X6 FROM S;
SELECT SUM(N) * AVG(N) X7 FROM S;
SELECT -VAR_SAMP(N) X8 FROM S;
SELECT VAR_SAMP(N) / VAR_POP(N) X9 FROM S;
SELECT NULLIF(VAR_POP(N), 0) XA FROM S;
SELECT CASE WHEN VAR_POP(N) > 1 THEN 'hi' ELSE 'lo' END XB FROM S;
SELECT REGR_COUNT(N, B) + 1 XC FROM S;
SELECT SUM(N + 1) * 2 XD FROM S;
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY N) * 2 XE FROM S;
SELECT CAST(COUNT(*) AS DOUBLE PRECISION) / VAR_POP(N) XF FROM S;
SQL
sof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sx1.sql" 2>&1 | norm; }
check "the family in select-list arithmetic and wrappers (ROUND/CAST/COALESCE/CASE/NULLIF/unary minus), mixed with plain folds" \
    "$(sof "127.0.0.1/$PORT:$A")" "$(sof "127.0.0.1/$REAL:$B")"

# --- NULL semantics: single-row and empty groups, COALESCE-exposed ---
cat > "$D/sx2.sql" <<'SQL'
SET LIST ON;
SELECT G, COALESCE(VAR_SAMP(N), -1) CV FROM S GROUP BY G ORDER BY G;
SELECT G, VAR_POP(N) + 1 VP1 FROM S GROUP BY G ORDER BY G;
SELECT COALESCE(STDDEV_SAMP(N), -9) E0 FROM S WHERE 1 = 0;
SELECT VAR_SAMP(N) + 1 E1 FROM S WHERE 1 = 0;
SELECT COALESCE(CORR(N, B), -7) E2 FROM S WHERE 1 = 0;
SELECT VAR_SAMP(N) BARE FROM S WHERE G = 3;
SQL
nof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sx2.sql" 2>&1 | norm; }
check "NULL semantics: VAR_SAMP(1 row)=NULL, VAR_POP(1 row)=0, empty set NULL - exposed by COALESCE, rendered 0.0 bare" \
    "$(nof "127.0.0.1/$PORT:$A")" "$(nof "127.0.0.1/$REAL:$B")"

# --- HAVING: bare family, expression forms, percentile ---
cat > "$D/sx3.sql" <<'SQL'
SET LIST ON;
SELECT G FROM S GROUP BY G HAVING VAR_SAMP(N) > 1 ORDER BY G;
SELECT G FROM S GROUP BY G HAVING STDDEV_POP(N) * 2 > 2 ORDER BY G;
SELECT G FROM S GROUP BY G HAVING SUM(N) * 2 > 10 ORDER BY G;
SELECT G FROM S GROUP BY G HAVING CORR(N, B) > 0.9 ORDER BY G;
SELECT G, COUNT(*) C FROM S GROUP BY G HAVING VAR_POP(N) < 2 ORDER BY G;
SELECT G FROM S GROUP BY G HAVING PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY N) > 3 ORDER BY G;
SELECT G FROM S GROUP BY G HAVING COVAR_POP(N, B) > 10 ORDER BY G;
SQL
hof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sx3.sql" 2>&1 | norm; }
check "HAVING with the family - bare, expression LHS, two-argument, percentile (NULL groups fail the predicate)" \
    "$(hof "127.0.0.1/$PORT:$A")" "$(hof "127.0.0.1/$REAL:$B")"

# --- ORDER BY aggregates and aggregate expressions ---
cat > "$D/sx4.sql" <<'SQL'
SET LIST ON;
SELECT G FROM S GROUP BY G ORDER BY SUM(N) DESC;
SELECT G FROM S GROUP BY G ORDER BY STDDEV_SAMP(N) DESC;
SELECT G FROM S GROUP BY G ORDER BY VAR_POP(N) * 2;
SELECT G FROM S GROUP BY G ORDER BY SUM(N) * 2;
SELECT G, PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY N) + 1 PD FROM S GROUP BY G ORDER BY G;
SQL
oof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sx4.sql" 2>&1 | norm; }
check "ORDER BY an aggregate / aggregate expression (a NULL STDDEV group sorts LAST even in DESC)" \
    "$(oof "127.0.0.1/$PORT:$A")" "$(oof "127.0.0.1/$REAL:$B")"

# --- the DESCRIBE pins: types AND the nullability split ---
cat > "$D/sx5.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SET PLANONLY ON;
SELECT STDDEV_SAMP(N) * 2 FROM S;
SELECT VAR_SAMP(N) + COUNT(*) FROM S;
SELECT SUM(N) * AVG(N) FROM S;
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY N) * 2 FROM S;
SELECT CASE WHEN VAR_POP(N) > 1 THEN 'hi' ELSE 'lo' END FROM S;
SELECT ROUND(VAR_POP(N), 2) FROM S;
SELECT COALESCE(VAR_SAMP(N), 0) FROM S;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sx5.sql" 2>&1 | grep sqltype | norm; }
check "SQLDA: DOUBLE not-nullable for the family's expressions, nullable for SUM*AVG (INT128 scale -4) and PERCENTILE, TEXT len 2 CASE" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# --- the review's live-verified catches, pinned differentially ---
cat > "$D/sx6.sql" <<'SQL'
SET LIST ON;
-- the DOUBLE-describe coercion runs BEFORE the exact-contract guards
-- (a Scaled/Int128 branch value 22003'd mid-fetch)
SELECT COALESCE(VAR_SAMP(N), 1.5) EV FROM S WHERE G > 100;
SELECT IIF(COUNT(*) > 0, SUM(N), VAR_POP(N)) I1 FROM S;
SELECT COALESCE(SUM(N), VAR_POP(N)) C2 FROM S;
-- ORDER BY an ALIAS of an aggregate expression sorts by the
-- EXPRESSION (it silently sorted by the first aggregate's slot)
SELECT G, 0 - SUM(N) AS X FROM S GROUP BY G ORDER BY X;
-- exact-vs-DOUBLE compares and the f64 folds convert by DIVIDE
-- (CVT_get_double); the multiply form picked WRONG ROWS silently
SELECT COUNT(*) W1 FROM S WHERE N = 7.05e0;
SELECT COUNT(*) W2 FROM S WHERE N > 7.05e0;
SELECT VAR_SAMP(N) VS FROM S WHERE G = 2;
-- PERCENTILE_DISC over a TEXT order compares as text in HAVING
SELECT G FROM S GROUP BY G HAVING PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY T) = 'e' ORDER BY G;
-- MIN/MAX over an expression keeps the NUMERIC sub_type
SELECT MAX(N * 2) + 0 M1 FROM S;
-- COALESCE nullability is ALL-branches (a nullable SUM branch keeps
-- the whole describe nullable; over an empty set isql shows <null>)
SELECT COALESCE(VAR_SAMP(N), SUM(B) * SUM(B)) CN FROM S WHERE 1 = 0;
SQL
rvf() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sx6.sql" 2>&1 | norm; }
check "review catches: guard-before-coercion, ORDER BY alias slot, divide-not-multiply f64, text PERCENTILE HAVING, describe rules" \
    "$(rvf "127.0.0.1/$PORT:$A")" "$(rvf "127.0.0.1/$REAL:$B")"

# --- boundaries stay refusals (fc-only pins; the engine serves or
# --- spells its own -104s) ---
ran=$((ran + 1))
bf=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT LIST(T) || 'x' FROM S;
SELECT VAR_SAMP(DISTINCT N) * 2 FROM S;
SELECT G FROM S WHERE VAR_SAMP(N) > 1;
SQL
)
case "$bf" in *"Dynamic SQL Error"*"Dynamic SQL Error"*"Dynamic SQL Error"*)
    echo "OK   boundaries refuse: LIST-in-expression, DISTINCT in the family, aggregate in WHERE";;
    *) echo "DIFF boundary refusals: [$bf]"; fail=1;; esac

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
