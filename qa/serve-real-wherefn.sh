#!/bin/bash
# FUNCTION CALLS IN WHERE - the predicate surface meets the built-in
# scalar functions. `WHERE UPPER(S) = 'X'`, `WHERE CHAR_LENGTH(S) > 3`,
# `WHERE MOD(A, 2) = 0` and their kin: a call on either side of a
# comparison, under IS [NOT] NULL, as a LIKE subject, inside BETWEEN/IN
# (which desugar to comparisons), combined with AND/OR/NOT - evaluated
# per row through the same expression machinery the select list uses,
# with the same three-valued logic the predicate surface always had.
#
# HISTORY NOTE: this gate originally enforced a "no-raise fence" -
# could-raise shapes refused at prepare, because a WHERE term answered
# only true/false. The wherexpr slice made predicates FALLIBLE (an
# eval error propagates with the engine's vector), so those shapes are
# ADMITTED now and checked differentially below; the fences that
# remain are the TYPE check (a text operand under MOD/SIGN/ABS) and
# the `?`-parameter-against-expression-side refusal.
#
# THE DIFFERENTIAL: the same isql runs the same SELECT against the
# engine and fire-crab on the same file; row sets must match exactly -
# including the NULL rows every function's UNKNOWN excludes, and the
# CHAR-padding cases where the compare must be pad-insensitive even
# though the function's RESULT carries the padding.
#
#   qa/serve-real-wherefn.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4484}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-wherefn.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  S VARCHAR(10),
  C CHAR(5),
  A INTEGER,
  N NUMERIC(9,2)
);
COMMIT;
INSERT INTO T VALUES (1, 'Hello', 'ab', -7, 12.50);
INSERT INTO T VALUES (2, 'wOrLd', 'xyz', 42, -1.25);
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL);
INSERT INTO T VALUES (4, '', 'a b', 0, 0.00);
INSERT INTO T VALUES (5, 'hello', 'AB', 13, 2.50);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-wherefn.log 2>&1 &
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

# --- a call on the LEFT of a comparison --------------------------------
same "UPPER = (case-folds both rows)"  "SELECT ID FROM T WHERE UPPER(S) = 'HELLO' ORDER BY ID"
same "LOWER ="                         "SELECT ID FROM T WHERE LOWER(S) = 'world' ORDER BY ID"
same "CHAR_LENGTH >"                   "SELECT ID FROM T WHERE CHAR_LENGTH(S) > 3 ORDER BY ID"
same "CHAR_LENGTH = 0 (empty string)"  "SELECT ID FROM T WHERE CHAR_LENGTH(S) = 0 ORDER BY ID"
same "MOD = (even test)"               "SELECT ID FROM T WHERE MOD(A, 2) = 0 ORDER BY ID"
same "MOD with a negative divisor"     "SELECT ID FROM T WHERE MOD(A, -2) = -1 ORDER BY ID"
same "ABS >"                           "SELECT ID FROM T WHERE ABS(A) > 10 ORDER BY ID"
same "SIGN ="                          "SELECT ID FROM T WHERE SIGN(A) = -1 ORDER BY ID"
same "SIGN over a NUMERIC"             "SELECT ID FROM T WHERE SIGN(N) = 1 ORDER BY ID"
same "SUBSTRING ="                     "SELECT ID FROM T WHERE SUBSTRING(S FROM 1 FOR 1) = 'H' ORDER BY ID"
same "TRIM of CHAR = (padding gone)"   "SELECT ID FROM T WHERE TRIM(C) = 'ab' ORDER BY ID"
same "UPPER of CHAR = (pad-insensitive compare)" "SELECT ID FROM T WHERE UPPER(C) = 'AB' ORDER BY ID"
same "POSITION >"                      "SELECT ID FROM T WHERE POSITION('l' IN S) > 0 ORDER BY ID"
same "REVERSE ="                       "SELECT ID FROM T WHERE REVERSE(S) = 'olleH' ORDER BY ID"
same "LEFT ="                          "SELECT ID FROM T WHERE LEFT(S, 2) = 'He' ORDER BY ID"
same "RIGHT ="                         "SELECT ID FROM T WHERE RIGHT(S, 3) = 'llo' ORDER BY ID"
same "LPAD ="                          "SELECT ID FROM T WHERE LPAD(S, 3, '*') = 'Hel' ORDER BY ID"
same "REPLACE ="                       "SELECT ID FROM T WHERE REPLACE(S, 'l', 'L') = 'HeLLo' ORDER BY ID"
same "nested calls"                    "SELECT ID FROM T WHERE UPPER(LEFT(S, 2)) = 'HE' ORDER BY ID"
same "CHAR_LENGTH of TRIM of CHAR"     "SELECT ID FROM T WHERE CHAR_LENGTH(TRIM(C)) = 2 ORDER BY ID"

# --- a call on the RIGHT, and on both sides ----------------------------
same "column = call"                   "SELECT ID FROM T WHERE S = TRIM('  Hello  ') ORDER BY ID"
same "call = call"                     "SELECT ID FROM T WHERE UPPER(S) = UPPER(C) ORDER BY ID"
same "length = length"                 "SELECT ID FROM T WHERE CHAR_LENGTH(S) = CHAR_LENGTH(TRIM(C)) ORDER BY ID"

# --- LIKE / BETWEEN / IN / IS NULL over calls --------------------------
same "call LIKE"                       "SELECT ID FROM T WHERE UPPER(S) LIKE 'H%' ORDER BY ID"
same "call NOT LIKE"                   "SELECT ID FROM T WHERE UPPER(S) NOT LIKE 'H%' ORDER BY ID"
same "call LIKE with _"                "SELECT ID FROM T WHERE LOWER(S) LIKE '_ello' ORDER BY ID"
same "call BETWEEN"                    "SELECT ID FROM T WHERE CHAR_LENGTH(S) BETWEEN 2 AND 5 ORDER BY ID"
same "call NOT BETWEEN"                "SELECT ID FROM T WHERE CHAR_LENGTH(S) NOT BETWEEN 2 AND 5 ORDER BY ID"
same "call IN"                         "SELECT ID FROM T WHERE UPPER(S) IN ('HELLO', 'X') ORDER BY ID"
same "call NOT IN"                     "SELECT ID FROM T WHERE UPPER(S) NOT IN ('HELLO', 'X') ORDER BY ID"
same "call IS NULL (two-valued)"       "SELECT ID FROM T WHERE UPPER(S) IS NULL ORDER BY ID"
same "call IS NOT NULL"                "SELECT ID FROM T WHERE UPPER(S) IS NOT NULL ORDER BY ID"

# --- boolean structure and three-valued logic --------------------------
same "NOT over a call comparison"      "SELECT ID FROM T WHERE NOT UPPER(S) = 'HELLO' ORDER BY ID"
same "AND of two calls"                "SELECT ID FROM T WHERE CHAR_LENGTH(S) > 3 AND MOD(A, 2) <> 0 ORDER BY ID"
same "OR of calls"                     "SELECT ID FROM T WHERE ABS(A) = 7 OR SIGN(A) = 0 ORDER BY ID"
same "call mixed with a plain term"    "SELECT ID FROM T WHERE UPPER(S) = 'HELLO' AND ID < 3 ORDER BY ID"
same "parenthesised OR under AND"      "SELECT ID FROM T WHERE (UPPER(S) = 'HELLO' OR UPPER(S) = 'WORLD') AND ID > 0 ORDER BY ID"

# --- the whole query surface composes ----------------------------------
same "COUNT(*) with a call filter"     "SELECT COUNT(*) FROM T WHERE CHAR_LENGTH(S) > 0"
same "projection + call filter"        "SELECT UPPER(S) FROM T WHERE CHAR_LENGTH(S) > 3 ORDER BY ID"
same "aggregate over a call filter"    "SELECT SUM(A) FROM T WHERE MOD(A, 2) = 0"
same "GROUP BY with a call filter"     "SELECT A, COUNT(*) FROM T WHERE CHAR_LENGTH(S) >= 0 GROUP BY A ORDER BY 1"

# --- DML takes the same predicates -------------------------------------
same "UPDATE with a call WHERE"        "UPDATE T SET A = 99 WHERE UPPER(S) = 'ZZZ'"
same "DELETE with a call WHERE"        "DELETE FROM T WHERE CHAR_LENGTH(S) = 999"
# a real UPDATE through the call predicate, read back on both sides
u1=$(printf 'UPDATE T SET A = 1000 WHERE UPPER(S) = %s;\nCOMMIT;\n' "'HELLO'" |
     "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1)
same "rows the UPDATE touched"         "SELECT ID, A FROM T ORDER BY ID"

# --- the once-fenced shapes now ANSWER (the fallible fold admitted
# --- them; serve-real-wherexpr.sh is their gate) - compared to the
# --- engine here, empty results and runtime errors alike
# the runtime divisor hits row 4's 0.00 and raises the same 22012 on
# both sides; the engine surfaces it at EXECUTE, fire-crab at first
# FETCH - one leading blank in isql (a documented difference)
out=$(printf 'SET HEADING OFF;\nSELECT ID FROM T WHERE MOD(A, N) = 0 ORDER BY ID;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"SQLSTATE = 22012"*) echo "OK   runtime MOD divisor raises 22012" ;;
    *) echo "DIFF runtime MOD divisor gave [$out]"; fail=1 ;;
esac
same "column LEFT length"           "SELECT ID FROM T WHERE LEFT(S, A) = 'x'"
same "column SUBSTRING length"      "SELECT ID FROM T WHERE SUBSTRING(S FROM 1 FOR A) = 'x'"
same "CAST in a predicate"          "SELECT ID FROM T WHERE CAST(A AS VARCHAR(5)) = '1'"

# --- refusals that remain, plus the raising divisor --------------------
for bad in "SELECT ID FROM T WHERE MOD(A, 0) = 0" \
           "SELECT ID FROM T WHERE UPPER(S, 2) = 'X'"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the NULL row must be excluded by UNKNOWN, both ways --------
v=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T WHERE UPPER(S) = %s OR NOT UPPER(S) = %s;\n' "'Q'" "'Q'" |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "4" ]; then
    echo "OK   teeth: x = 'Q' OR NOT x = 'Q' counts every non-NULL row (4), UNKNOWN both ways for NULL"
else
    echo "DIFF the tautology-with-UNKNOWN count was [$v], want 4"; fail=1
fi

exit $fail
