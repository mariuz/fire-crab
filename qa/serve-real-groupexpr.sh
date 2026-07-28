#!/bin/bash
# GROUP BY EXPRESSIONS - grouping keys that are computed per row, and
# the HAVING completion that rides with them.
#
#   GROUP BY UPPER(S)                      case-folded buckets
#   GROUP BY EXTRACT(YEAR FROM D)          calendar buckets
#   GROUP BY MOD(A, 2)                     parity buckets (the argument
#                                          comma must stay in its parens)
#   GROUP BY CASE WHEN ... END             conditional buckets
#   GROUP BY 1                             an ordinal naming an
#                                          EXPRESSION select item
#
# A select-list expression must BE one of the group's expression keys -
# matched STRUCTURALLY: both sides parse and the trees compare, so
# `GROUP BY upper( s )` matches `SELECT UPPER(S)` (column names compare
# case-insensitively; string literals keep their case). A bare column
# or an unmatched expression is the engine's "not contained in either
# an aggregate function or the GROUP BY clause" - fire-crab refuses.
# NULL keys bucket together, exactly as with column keys.
#
# HAVING grew with it, each shape probed:
#   * EXPRESSION aggregates: HAVING SUM(A + ID) > 5,
#     HAVING COUNT(NULLIF(A, 1)) > 0, HAVING SUM(IIF(...)) >= 1 -
#     folded as hidden output items (the aggregate lexer now scans to
#     the MATCHING paren, so nested calls lex as one token)
#   * NUMERIC aggregates: HAVING AVG(N) > 0, HAVING SUM(N) > 0.10 -
#     compared through the exact scale alignment (NumCmp)
#   * TEXT MIN/MAX: HAVING MIN(S) = 'apple' - the pad-trimming compare
#
#   qa/serve-real-groupexpr.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4489}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-groupexpr.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  G INTEGER,
  A INTEGER,
  N NUMERIC(9,2),
  S VARCHAR(10),
  D DATE
);
COMMIT;
INSERT INTO T VALUES (1, 1, 1,    12.50, 'pear',  DATE '2024-01-15');
INSERT INTO T VALUES (2, 1, 2,    1.25,  'Apple', DATE '1999-06-01');
INSERT INTO T VALUES (3, 2, 10,   -3.00, 'fig',   NULL);
INSERT INTO T VALUES (4, 2, NULL, NULL,  NULL,    DATE '2024-01-15');
INSERT INTO T VALUES (5, NULL, 7, 0.05,  'apple', DATE '1858-11-17');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-groupexpr.log 2>&1 &
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

# --- expression keys ---------------------------------------------------
same "GROUP BY UPPER(S)"            "SELECT UPPER(S), COUNT(*) FROM T GROUP BY UPPER(S) ORDER BY 1"
same "GROUP BY EXTRACT(YEAR)"       "SELECT EXTRACT(YEAR FROM D), COUNT(*), SUM(A) FROM T GROUP BY EXTRACT(YEAR FROM D) ORDER BY 1"
same "GROUP BY MOD (comma in parens)" "SELECT MOD(A, 2), COUNT(*) FROM T GROUP BY MOD(A, 2) ORDER BY 1"
same "GROUP BY CHAR_LENGTH"         "SELECT CHAR_LENGTH(S), COUNT(*) FROM T GROUP BY CHAR_LENGTH(S) ORDER BY 1"
same "GROUP BY SUBSTRING"           "SELECT SUBSTRING(S FROM 1 FOR 1), COUNT(*) FROM T GROUP BY SUBSTRING(S FROM 1 FOR 1) ORDER BY 1"
same "GROUP BY CASE"                "SELECT CASE WHEN A > 5 THEN 'big' ELSE 'small' END, COUNT(*) FROM T GROUP BY CASE WHEN A > 5 THEN 'big' ELSE 'small' END ORDER BY 1"
same "NULL keys bucket together"    "SELECT UPPER(S), COUNT(*) FROM T GROUP BY UPPER(S) ORDER BY 1"

# --- select-list / key matching ----------------------------------------
same "key omitted from the list"    "SELECT COUNT(*) FROM T GROUP BY UPPER(S) ORDER BY 1"
same "spacing and case differ"      "SELECT UPPER(S), COUNT(*) FROM T GROUP BY upper( s ) ORDER BY 1"
same "GROUP BY ordinal of an expr"  "SELECT UPPER(S), COUNT(*) FROM T GROUP BY 1 ORDER BY 1"
same "expr key beside a column key" "SELECT UPPER(S), G, COUNT(*) FROM T GROUP BY UPPER(S), G ORDER BY 1, 2"
same "aggregates over the buckets"  "SELECT EXTRACT(YEAR FROM D), MIN(S), MAX(N) FROM T GROUP BY EXTRACT(YEAR FROM D) ORDER BY 1"
same "expr key + expr aggregate"    "SELECT MOD(A, 2), SUM(A + ID) FROM T GROUP BY MOD(A, 2) ORDER BY 1"

# --- HAVING: expression aggregates -------------------------------------
same "HAVING SUM of an expression"  "SELECT G, SUM(A + ID) FROM T GROUP BY G HAVING SUM(A + ID) > 5 ORDER BY 1"
same "HAVING COUNT of NULLIF"       "SELECT G, COUNT(*) FROM T GROUP BY G HAVING COUNT(NULLIF(A, 1)) > 0 ORDER BY 1"
same "HAVING SUM of IIF"            "SELECT G, COUNT(*) FROM T GROUP BY G HAVING SUM(IIF(A > 5, 1, 0)) >= 1 ORDER BY 1"
same "HAVING hidden expr aggregate" "SELECT G FROM T GROUP BY G HAVING SUM(A + ID) > 5 ORDER BY 1"

# --- HAVING: numeric and text aggregates -------------------------------
same "HAVING AVG over NUMERIC"      "SELECT G, AVG(N) FROM T GROUP BY G HAVING AVG(N) > 0 ORDER BY 1"
same "HAVING SUM over NUMERIC vs decimal" "SELECT G, SUM(N) FROM T GROUP BY G HAVING SUM(N) > 0.10 ORDER BY 1"
same "HAVING numeric IS NOT NULL"   "SELECT G FROM T GROUP BY G HAVING SUM(N) IS NOT NULL ORDER BY 1"
same "HAVING MIN over text"         "SELECT G, MIN(S) FROM T GROUP BY G HAVING MIN(S) = 'apple' ORDER BY 1"
same "HAVING MAX of UPPER"          "SELECT G FROM T GROUP BY G HAVING MIN(UPPER(S)) = 'APPLE' ORDER BY 1"
same "HAVING over an expr-key group" "SELECT UPPER(S), COUNT(*) FROM T GROUP BY UPPER(S) HAVING COUNT(*) > 1 ORDER BY 1"

# --- headers: the key column carries the expression's name -------------
sameh "header UPPER key"            "SELECT UPPER(S), COUNT(*) FROM T GROUP BY UPPER(S) ORDER BY 1"
sameh "header EXTRACT key"          "SELECT EXTRACT(YEAR FROM D), COUNT(*) FROM T GROUP BY EXTRACT(YEAR FROM D) ORDER BY 1"

# --- refusals: ungrouped expressions and columns -----------------------
for bad in "SELECT S, COUNT(*) FROM T GROUP BY UPPER(S)" \
           "SELECT LOWER(S), COUNT(*) FROM T GROUP BY UPPER(S)" \
           "SELECT UPPER(S), COUNT(*) FROM T GROUP BY LOWER(S)" \
           "SELECT G, COUNT(*) FROM T GROUP BY G HAVING MIN(D) IS NULL"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the case-fold bucket merge, pinned to values ---------------
# 'Apple' and 'apple' must land in ONE bucket of 2 under UPPER(S)
v=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T GROUP BY UPPER(S) ORDER BY 1 DESC;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$v" in
    " 2 1 1 1 ") echo "OK   teeth: UPPER(S) merges 'Apple' and 'apple' into one bucket of 2" ;;
    *) echo "DIFF the case-fold buckets gave [$v], want [ 2 1 1 1 ]"; fail=1 ;;
esac

exit $fail
