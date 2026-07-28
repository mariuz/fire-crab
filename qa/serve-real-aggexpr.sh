#!/bin/bash
# AGGREGATES OVER EXPRESSIONS - the expression evaluator meets the
# aggregate folds. SUM(A + B), AVG(N * 2), MIN(UPPER(S)),
# COUNT(NULLIF(G, 1)), SUM(IIF(A > 5, 1, 0)) - the argument is any
# expression the surface can type, evaluated per row BEFORE the fold,
# in lone aggregates and GROUP BY buckets alike.
#
# The laws, probed before implementation:
#
#   * the RESULT TYPE follows the function and the SOURCE's type:
#     MIN/MAX keep the source's type (MIN(UPPER(S)) is text,
#     MIN(EXTRACT(YEAR FROM D)) an integer); SUM widens ONE STEP -
#     a LONG source announces BIGINT, an INT64-ranked source (a BIGINT
#     column, or A + B which types BIGINT) announces INT128 - while
#     AVG keeps BIGINT width unless the source is already INT128;
#     SUM/AVG keep the source's SCALE (SUM(N * 2) is NUMERIC(18,2))
#   * an eval error inside the argument raises MID-FETCH with the
#     engine's own vector: SUM(A / 0) is the divide-by-zero, not a
#     wrong sum - which is why the group fold is fallible
#   * COUNT(expr) counts non-NULL RESULTS (COUNT(NULLIF(G, 1)) skips
#     the rows NULLIF nulled out); SUM(IIF(cond, 1, 0)) is the classic
#     conditional counter and must equal the engine's
#
# This slice also closed a standing describe difference: a LONE
# aggregate's output column was headed CONSTANT where the engine names
# the FUNCTION (COUNT/MIN/MAX/SUM/AVG) - the header checks below pin
# the fix - and a GEN_ID read of a NONEXISTENT generator answered NULL
# where the engine raises; it now refuses.
#
#   qa/serve-real-aggexpr.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4488}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-aggexpr.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  G INTEGER,
  A INTEGER,
  N NUMERIC(9,2),
  S VARCHAR(10),
  D DATE,
  K BIGINT
);
COMMIT;
INSERT INTO T VALUES (1, 1, 1,    12.50, 'pear',  DATE '2024-01-15', 4000000000);
INSERT INTO T VALUES (2, 1, 2,    1.25,  'Apple', DATE '1999-06-01', -5);
INSERT INTO T VALUES (3, 2, 10,   -3.00, 'fig',   NULL,              7);
INSERT INTO T VALUES (4, 2, NULL, NULL,  NULL,    DATE '2024-01-15', NULL);
INSERT INTO T VALUES (5, NULL, 7, 0.05,  'apple', DATE '1858-11-17', 1);
COMMIT;
CREATE SEQUENCE AESEQ START WITH 41;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-aggexpr.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}
sameh() { # headers ON
    fc=$(printf '%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n=' ' ')
    en=$(printf '%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n=' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- arithmetic sources ------------------------------------------------
same "SUM of a sum of columns"      "SELECT SUM(A + ID) FROM T"
same "AVG of a product"             "SELECT AVG(A * 2) FROM T"
same "MIN of a difference"          "SELECT MIN(A - ID) FROM T"
same "SUM over scaled arithmetic"   "SELECT SUM(N * 2) FROM T"
same "AVG keeps the widest scale"   "SELECT AVG(N + 0.5) FROM T"
same "the three at once"            "SELECT SUM(A + ID), AVG(A * 2), MIN(A - ID) FROM T"

# --- function and conditional sources ----------------------------------
same "MIN of UPPER"                 "SELECT MIN(UPPER(S)) FROM T"
same "MAX of a concatenation"       "SELECT MAX(S || '!') FROM T"
same "SUM of CHAR_LENGTH"           "SELECT SUM(CHAR_LENGTH(S)) FROM T"
same "AVG of CHAR_LENGTH truncates" "SELECT AVG(CHAR_LENGTH(S)) FROM T"
same "MIN of EXTRACT"               "SELECT MIN(EXTRACT(YEAR FROM D)) FROM T"
same "SUM of IIF (conditional count)" "SELECT SUM(IIF(A > 5, 1, 0)) FROM T"
same "COUNT of NULLIF skips nulled rows" "SELECT COUNT(NULLIF(G, 1)) FROM T"
same "COUNT of an arithmetic expr"  "SELECT COUNT(A + ID) FROM T"
same "SUM of a CASE"                "SELECT SUM(CASE WHEN A > 5 THEN A ELSE 0 END) FROM T"

# --- grouped -----------------------------------------------------------
same "grouped SUM of an expr"       "SELECT G, SUM(A + ID) FROM T GROUP BY G ORDER BY 1"
same "grouped MIN of UPPER"         "SELECT G, MIN(UPPER(S)) FROM T GROUP BY G ORDER BY 1"
same "grouped mixed plain and expr" "SELECT G, COUNT(*), SUM(A + ID), AVG(N) FROM T GROUP BY G ORDER BY 1"

# --- the widening laws (values compare equal; the DESCRIBE differs
# --- only in width, which the squeeze hides - so pin values + headers)
same "SUM of BIGINT column (INT128 announce)" "SELECT SUM(K) FROM T"
same "SUM of BIGINT-typed expr"     "SELECT SUM(A + ID) FROM T WHERE ID < 3"
same "AVG of BIGINT stays BIGINT"   "SELECT AVG(K) FROM T"

# --- composition with the rest of the surface --------------------------
same "expr agg + WHERE function"    "SELECT SUM(A + ID) FROM T WHERE CHAR_LENGTH(S) > 3"
same "expr agg over empty set"      "SELECT SUM(A + ID), COUNT(A + ID) FROM T WHERE ID > 90"
same "expr agg + plain agg + WHERE" "SELECT COUNT(*), MIN(A), SUM(A) FROM T WHERE ID > 90"

# --- the eval-error conduit: SUM(A / 0) raises MID-FETCH ---------------
same "divide by zero inside SUM"    "SELECT SUM(A / 0) FROM T"
# the conversion error raises 22018 on both sides; the engine's message
# carries the offending string as a vector argument fire-crab does not
# ship yet (a named difference, see expression-surface.md) - so this
# check asserts the matching SQLSTATE, not the argument text
out=$(printf 'SELECT MIN(CAST(S AS INTEGER)) FROM T;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"SQLSTATE = 22018"*) echo "OK   conversion error inside MIN raises 22018" ;;
    *) echo "DIFF MIN(CAST(S AS INTEGER)) gave [$out], want SQLSTATE 22018"; fail=1 ;;
esac

# --- headers: lone aggregates name their FUNCTION (the fixed describe) -
sameh "header COUNT(*)"             "SELECT COUNT(*) FROM T"
sameh "header SUM"                  "SELECT SUM(A) FROM T"
sameh "header MIN"                  "SELECT MIN(A) FROM T"
sameh "header MAX"                  "SELECT MAX(A) FROM T"
sameh "header GEN_ID"               "SELECT GEN_ID(AESEQ, 0) FROM RDB\$DATABASE"

# --- refusals ----------------------------------------------------------
for bad in "SELECT SUM(UPPER(S)) FROM T" \
           "SELECT AVG(S || '!') FROM T" \
           "SELECT SUM(NOSUCHCOL + 1) FROM T" \
           "SELECT GEN_ID(NOSUCHGEN, 0) FROM RDB\$DATABASE" \
           "SELECT G FROM T GROUP BY G HAVING SUM(A + ID) > 5"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the conditional-counter identity, pinned to a value --------
v=$(printf 'SET HEADING OFF;\nSELECT SUM(IIF(A > 5, 1, 0)) FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "2" ]; then
    echo "OK   teeth: SUM(IIF(A > 5, 1, 0)) counts the two matching rows"
else
    echo "DIFF the conditional counter gave [$v], want 2"; fail=1
fi

exit $fail
