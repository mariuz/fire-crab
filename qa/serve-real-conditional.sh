#!/bin/bash
# CONDITIONAL EXPRESSIONS - COALESCE, NULLIF, IIF.
#
# These join the select-list expression surface (the same parser and
# evaluator that handle arithmetic, ||, CAST and computed columns), so
# they nest inside arithmetic and each other, and a computed column can
# be defined with one.
#
# The three NULL rules are the whole content of the feature, and each is
# a place a plausible implementation goes wrong:
#
#   COALESCE(a, b, ...)  the first operand that is NOT NULL; NULL only
#                        when every one of them is
#   NULLIF(a, b)         NULL when the two are EQUAL. A NULL operand
#                        makes the comparison UNKNOWN, which is NOT
#                        equal, so `a` comes through - and is itself NULL
#                        when a was NULL
#   IIF(cond, a, b)      ONLY a TRUE condition takes `a`. False AND
#                        UNKNOWN both take `b`, so `IIF(x > 1, ...)` with
#                        x NULL takes the ELSE branch
#
# A conditional's TYPE and WIDTH come from its branches: the first branch
# that types wins, and the widest decides the width, so a value from any
# branch fits the column the describe announced.
#
# THE DIFFERENTIAL: the same isql runs the same SELECT against the engine
# and against fire-crab, and the values must match - NULLs included,
# which is the point.
#
# Two wrong-answer paths that this surface used to have, both now closed
# and asserted below:
#
#   * a conditional mixing a SCALED NUMERIC column with a decimal literal
#     (`COALESCE(N, 0.00)`) typed as Numeric but could not SIZE itself,
#     because result_scale had no arm for a conditional. A conditional's
#     scale is its WIDEST branch's - and scales are negative, so widest is
#     the MINIMUM; anything narrower truncates a branch's value into a
#     column that cannot hold it.
#   * a wrong-arity call (`COALESCE(A)`) had its parse decline, the text
#     read as a column name, and the whole query fall back to the
#     fixed-answer plan - 4242 in reply to a broken function call. Any
#     failure to resolve a select list that NAMES a conditional now
#     raises instead.
#
#   qa/serve-real-conditional.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4482}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-conditional.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  A INTEGER,
  B INTEGER,
  S VARCHAR(10),
  N NUMERIC(9,2),
  K BIGINT
);
COMMIT;
INSERT INTO T VALUES (1, 10, 10, 'x', 12.50, 4000000000);
INSERT INTO T VALUES (2, 20, 30, 'y', 1.25, 5);
INSERT INTO T VALUES (3, NULL, 7, NULL, NULL, NULL);
INSERT INTO T VALUES (4, 0, NULL, '', 0.00, 0);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cond.log 2>&1 &
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

# --- COALESCE ----------------------------------------------------------
same "COALESCE, two operands"       "SELECT COALESCE(A, 0) FROM T ORDER BY ID"
same "COALESCE, three operands"     "SELECT COALESCE(A, B, 99) FROM T ORDER BY ID"
same "COALESCE where all are NULL"  "SELECT COALESCE(A, N) FROM T WHERE ID = 3"
same "COALESCE picks the first non-NULL" "SELECT COALESCE(B, A, 42) FROM T ORDER BY ID"
same "COALESCE over text"           "SELECT COALESCE(S, 'none') FROM T ORDER BY ID"
same "COALESCE with a literal first" "SELECT COALESCE(7, A) FROM T ORDER BY ID"
same "COALESCE over a scaled NUMERIC"  "SELECT COALESCE(N, 0.00) FROM T ORDER BY ID"
same "COALESCE, NUMERIC and an integer literal" "SELECT COALESCE(N, 0) FROM T ORDER BY ID"
same "NULLIF over a scaled NUMERIC"    "SELECT NULLIF(N, 12.50) FROM T ORDER BY ID"
same "IIF returning a scaled NUMERIC"  "SELECT IIF(N IS NULL, 0.00, N) FROM T ORDER BY ID"
same "COALESCE over a BIGINT"       "SELECT COALESCE(K, 0) FROM T ORDER BY ID"

# --- NULLIF ------------------------------------------------------------
same "NULLIF, equal operands"       "SELECT NULLIF(A, B) FROM T ORDER BY ID"
same "NULLIF against a literal"     "SELECT NULLIF(A, 20) FROM T ORDER BY ID"
same "NULLIF that never matches"    "SELECT NULLIF(A, 999) FROM T ORDER BY ID"
same "NULLIF with a NULL operand"   "SELECT NULLIF(A, N) FROM T ORDER BY ID"
same "NULLIF over text"             "SELECT NULLIF(S, 'x') FROM T ORDER BY ID"
same "NULLIF on zero"               "SELECT NULLIF(A, 0) FROM T ORDER BY ID"

# --- IIF ---------------------------------------------------------------
same "IIF on a comparison"          "SELECT IIF(A > 15, 1, 0) FROM T ORDER BY ID"
same "IIF returning columns"        "SELECT IIF(A > B, A, B) FROM T ORDER BY ID"
same "IIF on IS NULL"               "SELECT IIF(A IS NULL, -1, A) FROM T ORDER BY ID"
same "IIF on IS NOT NULL"           "SELECT IIF(A IS NOT NULL, A, -1) FROM T ORDER BY ID"
same "IIF on equality"              "SELECT IIF(A = B, 1, 0) FROM T ORDER BY ID"
same "IIF on inequality"            "SELECT IIF(A <> B, 1, 0) FROM T ORDER BY ID"
same "IIF on <="                    "SELECT IIF(A <= B, 1, 0) FROM T ORDER BY ID"
same "IIF over text"                "SELECT IIF(S = 'x', 'is x', 'not x') FROM T ORDER BY ID"

# --- nesting, and mixing with the rest of the expression surface -------
same "COALESCE inside arithmetic"   "SELECT COALESCE(A, 0) + 1 FROM T ORDER BY ID"
same "arithmetic inside COALESCE"   "SELECT COALESCE(A + B, 0) FROM T ORDER BY ID"
same "COALESCE inside COALESCE"     "SELECT COALESCE(COALESCE(A, B), 99) FROM T ORDER BY ID"
same "NULLIF inside COALESCE"       "SELECT COALESCE(NULLIF(A, 10), 77) FROM T ORDER BY ID"
same "IIF inside arithmetic"        "SELECT IIF(A IS NULL, 0, A) * 2 FROM T ORDER BY ID"
same "COALESCE inside IIF"          "SELECT IIF(A IS NULL, COALESCE(B, 0), A) FROM T ORDER BY ID"
same "COALESCE with CAST"           "SELECT COALESCE(CAST(A AS BIGINT), 0) FROM T ORDER BY ID"
same "COALESCE with concatenation"  "SELECT COALESCE(S, 'n') || '!' FROM T ORDER BY ID"
same "several conditionals at once" "SELECT COALESCE(A, 0), NULLIF(B, 7), IIF(A > 5, 1, 0) FROM T ORDER BY ID"

# --- teeth: the three NULL rules, each pinned to a value --------------
row3() { printf 'SET HEADING OFF;\n%s;\n' "$1" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n'; }
# COALESCE must skip the NULL and take the next
v=$(row3 "SELECT COALESCE(A, B) FROM T WHERE ID = 3")
if [ "$v" = "7" ]; then
    echo "OK   teeth: COALESCE skipped the NULL and took B (7)"
else
    echo "DIFF COALESCE(A, B) on the NULL row gave [$v], want 7"; fail=1
fi
# NULLIF with a NULL operand must NOT be equal, so `a` (NULL) comes back
v=$(row3 "SELECT NULLIF(A, N) FROM T WHERE ID = 3")
case "$v" in
    *null*|*NULL*) echo "OK   teeth: NULLIF with a NULL operand returns the first operand" ;;
    *) echo "DIFF NULLIF(A, N) on the NULL row gave [$v], want NULL"; fail=1 ;;
esac
# IIF must take the ELSE branch when the condition is UNKNOWN
v=$(row3 "SELECT IIF(A > 1, 111, 222) FROM T WHERE ID = 3")
if [ "$v" = "222" ]; then
    echo "OK   teeth: an UNKNOWN condition takes the ELSE branch (222)"
else
    echo "DIFF IIF with an UNKNOWN condition gave [$v], want 222"; fail=1
fi

# a wrong-arity call must RAISE, not answer the fixed-answer constant
for bad in "SELECT COALESCE(A) FROM T" "SELECT NULLIF(A) FROM T" \
           "SELECT NULLIF(A, 1, 2) FROM T" "SELECT IIF(A > 1) FROM T"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *"Statement failed"*|*error*|*ERROR*)
            echo "OK   teeth: [$bad] is refused" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done
# ...and the fixed-answer constant must appear NOWHERE in this gate's
# answers, since every query here is one the server should either answer
# correctly or refuse
out=$(printf 'SET HEADING OFF;\nSELECT COALESCE(A, 0) FROM T;\nSELECT NULLIF(A, 10) FROM T;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1)
case "$out" in
    *4242*) echo "DIFF the fixed-answer constant 4242 leaked into a conditional's result"; fail=1 ;;
    *) echo "OK   teeth: no fixed-answer constant in any conditional result" ;;
esac

exit $fail
