#!/bin/bash
# THE AGGREGATE SURFACE BEYOND INTEGERS - AVG, MIN/MAX over text and
# temporal columns, SUM/AVG over scaled numerics, COUNT(DISTINCT col).
#
# The laws are the content, each probed against the live engine BEFORE
# implementation:
#
#   * AVG is SUM / COUNT-of-non-NULLs, the division TRUNCATING toward
#     zero at the operand's scale: AVG over integers 1,2 is 1 (not 1.5,
#     not 2); AVG over NUMERIC(9,2) values summing -2.95 across 2 rows
#     is -1.47 (toward zero - floor would say -1.48)
#   * the result TYPE follows the function and the column: AVG/SUM over
#     INTEGER announce BIGINT; over NUMERIC(9,2) they keep scale -2 at
#     BIGINT width (the engine's NUMERIC(18,2) widening); MIN/MAX keep
#     the COLUMN's own type - a VARCHAR stays VARCHAR, a DATE stays DATE
#   * NULLs are skipped by every fold; an empty or all-NULL input is
#     NULL for MIN/MAX/SUM/AVG and 0 for COUNT(col); COUNT(*) counts
#     rows regardless
#   * MIN/MAX over text follow the column's collation order - byte
#     order here ('Apple' < 'apple' < 'pear'), trailing blanks not
#     significant
#   * COUNT(DISTINCT col) counts distinct NON-NULL values (NULL is not
#     a value); DISTINCT under SUM/AVG/MIN/MAX is refused, not guessed
#
# THE DIFFERENTIAL: the same isql runs the same SELECT against the
# engine and fire-crab on the same file - lone aggregates, WHERE
# filters, GROUP BY with NULL keys, HAVING over hidden aggregates.
#
#   qa/serve-real-aggfn.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4487}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-aggfn.fdb"

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
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-aggfn.log 2>&1 &
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

# --- AVG: the truncating division --------------------------------------
same "AVG over integers truncates"   "SELECT AVG(A) FROM T"
same "AVG over BIGINT"               "SELECT AVG(K) FROM T"
same "AVG keeps NUMERIC scale"       "SELECT AVG(N) FROM T"
same "AVG truncates toward zero"     "SELECT AVG(N) FROM T WHERE N < 0.10"
same "AVG with WHERE"                "SELECT AVG(A) FROM T WHERE ID < 3"
same "AVG over the empty set"        "SELECT AVG(A) FROM T WHERE ID > 90"
same "AVG skips NULLs"               "SELECT AVG(A) FROM T WHERE G = 2"

# --- SUM/MIN/MAX over scaled numerics ----------------------------------
same "SUM keeps NUMERIC scale"       "SELECT SUM(N) FROM T"
same "MIN/MAX over NUMERIC"          "SELECT MIN(N), MAX(N) FROM T"
same "SUM over BIGINT"               "SELECT SUM(K) FROM T"

# --- MIN/MAX over text and temporal ------------------------------------
same "MIN/MAX over text (byte order)" "SELECT MIN(S), MAX(S) FROM T"
same "MIN/MAX over DATE"             "SELECT MIN(D), MAX(D) FROM T"
same "MIN over text with WHERE"      "SELECT MIN(S) FROM T WHERE ID > 2"
same "MIN/MAX text all-NULL group"   "SELECT MIN(S) FROM T WHERE ID = 4"

# --- COUNT(DISTINCT) ---------------------------------------------------
same "COUNT DISTINCT skips NULLs"    "SELECT COUNT(DISTINCT G) FROM T"
same "COUNT DISTINCT text case"      "SELECT COUNT(DISTINCT S) FROM T"
same "COUNT DISTINCT vs COUNT"       "SELECT COUNT(DISTINCT G), COUNT(G), COUNT(*) FROM T"

# --- grouped: the same laws per bucket ---------------------------------
same "GROUP BY with AVG/SUM/MIN"     "SELECT G, AVG(A), SUM(N), MIN(S) FROM T GROUP BY G ORDER BY 1"
same "GROUP BY with MIN/MAX dates"   "SELECT G, MIN(D), MAX(D) FROM T GROUP BY G ORDER BY 1"
same "GROUP BY COUNT DISTINCT"       "SELECT G, COUNT(DISTINCT S) FROM T GROUP BY G ORDER BY 1"
same "multi-aggregate global group"  "SELECT AVG(A), SUM(N), MIN(S), MAX(D), COUNT(*) FROM T"
same "HAVING over a hidden AVG"      "SELECT G, AVG(N) FROM T GROUP BY G HAVING AVG(A) > 5 ORDER BY 1"
same "HAVING keeps AVG in the list"  "SELECT G, AVG(A) FROM T GROUP BY G HAVING AVG(A) >= 1 ORDER BY 1"
same "aggregates + WHERE + GROUP BY" "SELECT G, AVG(A) FROM T WHERE ID < 5 GROUP BY G ORDER BY 1"

# --- aggregate filters compose with the newer surfaces -----------------
same "AVG over a function filter"    "SELECT AVG(A) FROM T WHERE CHAR_LENGTH(S) > 3"
same "SUM over an EXTRACT filter"    "SELECT SUM(A) FROM T WHERE EXTRACT(YEAR FROM D) = 2024"

# --- headers -----------------------------------------------------------
sameh "header AVG"                   "SELECT AVG(A) FROM T"
sameh "header COUNT for DISTINCT"    "SELECT COUNT(DISTINCT G) FROM T"
sameh "MIN of text describes as the column" "SELECT MIN(S) FROM T"

# --- refusals ----------------------------------------------------------
for bad in "SELECT SUM(DISTINCT A) FROM T" \
           "SELECT AVG(DISTINCT A) FROM T" \
           "SELECT AVG(S) FROM T" \
           "SELECT SUM(D) FROM T" \
           "SELECT AVG(*) FROM T"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the two laws pinned to values ------------------------------
v=$(printf 'SET HEADING OFF;\nSELECT AVG(A) FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "5" ]; then
    echo "OK   teeth: AVG(1,2,10,7) is 5 - 20/4 truncating, NULL skipped"
else
    echo "DIFF AVG(A) gave [$v], want 5"; fail=1
fi
v=$(printf 'SET HEADING OFF;\nSELECT AVG(N) FROM T WHERE N < 0.10;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "-1.47" ]; then
    echo "OK   teeth: AVG(-3.00, 0.05) is -1.47 - truncation TOWARD ZERO"
else
    echo "DIFF the negative AVG gave [$v], want -1.47"; fail=1
fi

exit $fail
