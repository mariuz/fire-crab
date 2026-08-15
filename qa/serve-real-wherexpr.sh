#!/bin/bash
# EXPRESSIONS EVERYWHERE IN WHERE - and the FALLIBLE PREDICATE that
# makes them honest.
#
#   WHERE A + 1 > B          arithmetic on either side
#   WHERE A = ID             column against column
#   WHERE (A + ID) * 2 = 4   parenthesised expression sides
#   WHERE A / 0 = 1          RAISES the divide-by-zero mid-statement
#   WHERE MOD(A, ID) = 0     runtime divisors
#   WHERE COALESCE(A, 0) > 5 conditionals and CAST as predicate sides
#
# The architectural change under it: Predicate/Term::matches became
# FALLIBLE. Before this slice a WHERE term answered only true/false,
# so any shape whose evaluation could raise was refused at prepare
# (the "no-raise fence"). Now a per-row eval error PROPAGATES through
# every predicate consumer - the row walk, DML target collection,
# CHECK enforcement, HAVING, the group input filter - and reaches the
# client as the engine's own status vector, exactly where the engine
# raises it. The fence is gone; the previously-fenced shapes (MOD with
# a runtime divisor, LEFT with a column length, CAST, DATEADD) are
# admitted, and the error cases now match the engine value for value
# ON SELECT PATHS. Known difference, documented not silent: a DML
# statement whose WHERE raises answers a generic SQL error where the
# engine carries the 22012 vector (the DML error channel is text).
#
#   qa/serve-real-wherexpr.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4491}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-wherexpr.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  A INTEGER,
  B INTEGER,
  N NUMERIC(9,2),
  S VARCHAR(10)
);
COMMIT;
INSERT INTO T VALUES (1, 1, 2, 12.50, 'pear');
INSERT INTO T VALUES (2, 2, 2, 1.25, 'Apple');
INSERT INTO T VALUES (3, 10, 5, -3.00, 'fig');
INSERT INTO T VALUES (4, NULL, 1, NULL, NULL);
INSERT INTO T VALUES (5, 7, 0, 0.05, 'apple');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-wherexpr.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

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

# --- arithmetic sides --------------------------------------------------
same "sum of columns vs literal"    "SELECT ID FROM T WHERE A + B > 5 ORDER BY ID"
same "product vs literal"           "SELECT ID FROM T WHERE A * 2 = 20"
same "column vs column"             "SELECT ID FROM T WHERE A = B ORDER BY ID"
same "column vs column inequality"  "SELECT ID FROM T WHERE A > B ORDER BY ID"
same "parenthesised side"           "SELECT ID FROM T WHERE (A + B) * 2 = 6 ORDER BY ID"
same "arithmetic both sides"        "SELECT ID FROM T WHERE A + 1 = B * 1 ORDER BY ID"
same "scaled arithmetic side"       "SELECT ID FROM T WHERE N + 0.25 > 1 ORDER BY ID"
same "subtraction side"             "SELECT ID FROM T WHERE CHAR_LENGTH(S) - 1 = 3 ORDER BY ID"
same "unary minus side"             "SELECT ID FROM T WHERE -A = -10"
same "expr vs expr functions"       "SELECT ID FROM T WHERE A + 1 = CHAR_LENGTH(S) ORDER BY ID"

# --- BETWEEN / IN with expression bounds -------------------------------
same "arithmetic BETWEEN"           "SELECT ID FROM T WHERE A + 1 BETWEEN 2 AND 8 ORDER BY ID"
same "expression bound"             "SELECT ID FROM T WHERE A BETWEEN B - 1 AND B + 8 ORDER BY ID"
same "arithmetic IN"                "SELECT ID FROM T WHERE A - 1 IN (0, 9) ORDER BY ID"

# --- conditionals and CAST as predicate sides --------------------------
same "COALESCE side"                "SELECT ID FROM T WHERE COALESCE(A, 0) > 5 ORDER BY ID"
same "IIF side"                     "SELECT ID FROM T WHERE IIF(A > 5, 1, 0) = 1 ORDER BY ID"
same "NULLIF IS NULL"               "SELECT ID FROM T WHERE NULLIF(A, 2) IS NULL ORDER BY ID"
same "CAST side"                    "SELECT ID FROM T WHERE CAST(A AS VARCHAR(5)) = '10'"

# --- the fallible fold: eval errors raise like the engine's ------------
same "divide by zero raises"        "SELECT ID FROM T WHERE A / 0 = 1"
same "runtime divisor works"        "SELECT ID FROM T WHERE MOD(A, ID) = 0 ORDER BY ID"
same "column length goes negative"  "SELECT ID FROM T WHERE LEFT(S, A - 100) = 'x'"
# these two raise the same 22012 VECTOR on both sides, but the engine
# surfaces it at EXECUTE while fire-crab surfaces it at first FETCH -
# one leading blank line in isql's output (documented, not silent);
# the 22018 additionally lacks the offending-string argument (the
# standing named difference)
sqlstate() { # <label> <sql> <state>
    out=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
          "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *"SQLSTATE = $3"*) echo "OK   $1" ;;
        *) echo "DIFF $1 gave [$out], want SQLSTATE $3"; fail=1 ;;
    esac
}
sqlstate "runtime divisor hits zero"   "SELECT ID FROM T WHERE MOD(A, B) = 1 ORDER BY ID" 22012
# the 22018 carries its offending string now - exact differential
same "bad cast raises 22018 with the string" "SELECT ID FROM T WHERE CAST(S AS INTEGER) = 1"
sqlstate "error after matching rows"   "SELECT ID FROM T WHERE 100 / B > 10 ORDER BY ID" 22012

# --- composition -------------------------------------------------------
same "COUNT over an expr filter"    "SELECT COUNT(*) FROM T WHERE A + B > 5"
same "aggregate + expr filter"      "SELECT SUM(A) FROM T WHERE A * 2 >= 4"
same "GROUP BY + expr filter"       "SELECT B, COUNT(*) FROM T WHERE A + 1 >= 2 GROUP BY B ORDER BY 1"
same "AND mixes expr and classic"   "SELECT ID FROM T WHERE S LIKE 'p%' AND A + 1 = 2"
same "OR with UNKNOWN rows"         "SELECT ID FROM T WHERE A + 1 = 2 OR A = B ORDER BY ID"
same "params still bind beside exprs" "SELECT ID FROM T WHERE A = 10 AND N > -99 ORDER BY ID"

# --- DML with expression WHERE -----------------------------------------
same "UPDATE with expr WHERE"       "UPDATE T SET B = B WHERE A + 1 = 999"
same "DELETE with expr WHERE"       "DELETE FROM T WHERE A * 2 = 999999"
# a DML whose WHERE raises answers the engine's own 22012 vector now
same "DML with a raising WHERE"     "UPDATE T SET B = B WHERE A / 0 = 1"

# CASE-in-WHERE and ?-against-expressions joined the surface with the
# predfull slice (its gate covers them); what remains refused:
same "CASE in WHERE answers now"    "SELECT ID FROM T WHERE CASE WHEN A > 1 THEN 1 ELSE 0 END = 1 ORDER BY ID"

# --- `||` string concatenation as a WHERE expression -------------------
# the token-level parser learned `||` (tighter than the arithmetic ops,
# left-associative), so a concatenation is a WHERE side like any other:
# compared, LIKE'd, STARTING-tested, and NULL-propagating (NULL||x = NULL).
same "concat = literal"             "SELECT ID FROM T WHERE S||'x' = 'pearx'"
same "concat LIKE"                  "SELECT ID FROM T WHERE S||'!' LIKE 'apple%' ORDER BY ID"
same "concat STARTING WITH"         "SELECT ID FROM T WHERE S||S STARTING WITH 'fig'"
same "two columns concat"           "SELECT ID FROM T WHERE S||S = 'figfig'"
same "multi concat, left-assoc"     "SELECT ID FROM T WHERE S||'-'||S = 'fig-fig'"
same "literal-first concat"         "SELECT ID FROM T WHERE 'z'||S = 'zpear'"
same "concat with a CAST"           "SELECT ID FROM T WHERE S||CAST(A AS VARCHAR(3)) = 'pear1'"
same "NULL propagates through ||"   "SELECT ID FROM T WHERE S||'x' IS NULL"
same "concat in AND beside classic" "SELECT ID FROM T WHERE S||'x' LIKE 'a%' AND A > 0 ORDER BY ID"

# --- refusals that REMAIN ----------------------------------------------
for bad in "SELECT ID FROM T WHERE DECODE(A, 1, 2) = 2" \
           "SELECT ID FROM T WHERE A = ? + 1"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the error must arrive AFTER the rows that matched ----------
# 100 / B: rows sort by ID; row 5 has B = 0 - the engine ships the rows
# before it and then raises; a swallowing implementation would return
# them ALL with row 5 silently dropped
v=$(printf 'SET HEADING OFF;\nSELECT ID FROM T WHERE 100 / B > 10 ORDER BY ID;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$v" in
    *"SQLSTATE = 22012"*) echo "OK   teeth: the divide-by-zero row RAISES instead of silently dropping" ;;
    *) echo "DIFF the raising row gave [$v], want a 22012"; fail=1 ;;
esac

exit $fail
