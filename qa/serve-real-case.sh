#!/bin/bash
# CASE EXPRESSIONS - searched and simple, with full boolean conditions.
#
#   CASE WHEN <cond> THEN <expr> [WHEN ...] [ELSE <expr>] END
#   CASE <operand> WHEN <value> THEN <expr> [...] [ELSE <expr>] END
#
# The engine parses IIF into a searched CASE (an un-aliased IIF headers
# as CASE), so this slice also upgrades IIF's condition to the full
# boolean grammar: OR over AND over NOT over parenthesised groups over
# comparisons and NULL tests, all three-valued (Kleene): FALSE dominates
# AND, TRUE dominates OR, UNKNOWN dominates the recessive value, NOT of
# UNKNOWN stays UNKNOWN. Only a TRUE condition takes a branch - false
# and UNKNOWN both move on - the ELSE takes the rest, and a missing
# ELSE is NULL.
#
# The simple form desugars into `<operand> = <value>` conditions, which
# carries the engine's famous rule for free: `WHEN NULL` NEVER matches
# (x = NULL is UNKNOWN), and a NULL operand matches nothing - both
# probed before implementation and both differential-checked here.
#
# TYPING ACROSS BRANCHES is this gate's second subject, because writing
# it found a STANDING BUG in the older conditionals: a conditional's
# type came from its first branch alone, so COALESCE(A, 0.5) - integer
# first, scaled second - announced scale 0 and the scaled branch's raw
# value could not decode. Two rules fixed it, both engine-probed:
#
#   * ANY exact-numeric branch beside integer ones types the whole
#     conditional Numeric, at the branches' MINIMUM (widest) scale -
#     the engine prints COALESCE(A, 0.5) as -7.0, scale -1
#   * each branch's value is ALIGNED to that announced scale at emit
#     (0.5 announced at -2 travels as raw 50, not raw 5)
#
#   qa/serve-real-case.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4539}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-case.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  S VARCHAR(10),
  A INTEGER,
  N NUMERIC(9,2),
  K BIGINT
);
COMMIT;
INSERT INTO T VALUES (1, 'Hello', -7, 12.50, 4000000000);
INSERT INTO T VALUES (2, 'world', 42, -1.25, -5);
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL);
INSERT INTO T VALUES (4, '', 0, 0.00, 0);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-case.log 2>&1 &
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

# --- searched CASE -----------------------------------------------------
same "three branches with ELSE"     "SELECT CASE WHEN A > 0 THEN 'pos' WHEN A < 0 THEN 'neg' ELSE 'zero' END FROM T ORDER BY ID"
same "first TRUE branch wins"       "SELECT CASE WHEN A < 0 THEN 'first' WHEN A = -7 THEN 'second' END FROM T ORDER BY ID"
same "missing ELSE is NULL"         "SELECT CASE WHEN A > 0 THEN 'pos' END FROM T ORDER BY ID"
same "UNKNOWN conds fall to ELSE"   "SELECT CASE WHEN A > 0 THEN 'p' WHEN A < 0 THEN 'n' ELSE 'e' END FROM T ORDER BY ID"
same "IS NULL as a condition"       "SELECT CASE WHEN S IS NULL THEN 'isnull' ELSE 'notnull' END FROM T ORDER BY ID"
same "IS NOT NULL as a condition"   "SELECT CASE WHEN A IS NOT NULL THEN A ELSE -1 END FROM T ORDER BY ID"

# --- simple CASE -------------------------------------------------------
same "simple, integer operand"      "SELECT CASE A WHEN -7 THEN 'minus7' WHEN 42 THEN 'answer' ELSE 'other' END FROM T ORDER BY ID"
same "simple, text operand"         "SELECT CASE S WHEN 'Hello' THEN 'greet' WHEN '' THEN 'empty' ELSE 'other' END FROM T ORDER BY ID"
same "simple, WHEN NULL never matches" "SELECT CASE S WHEN NULL THEN 'isnull' ELSE 'notnull' END FROM T ORDER BY ID"
same "simple, NULL operand takes ELSE" "SELECT CASE A WHEN 1 THEN 'one' ELSE 'other' END FROM T ORDER BY ID"
same "simple without ELSE"          "SELECT CASE A WHEN 42 THEN 'answer' END FROM T ORDER BY ID"
same "simple over a NUMERIC"        "SELECT CASE N WHEN 12.50 THEN 'exact' ELSE 'other' END FROM T ORDER BY ID"

# --- boolean conditions: AND / OR / NOT / parens, three-valued ---------
same "AND condition"                "SELECT CASE WHEN A < 0 AND N > 1 THEN 'both' ELSE 'no' END FROM T ORDER BY ID"
same "OR condition"                 "SELECT CASE WHEN A > 0 OR N > 1 THEN 'either' ELSE 'no' END FROM T ORDER BY ID"
same "NOT condition"                "SELECT CASE WHEN NOT A > 0 THEN 'notpos' ELSE 'pos' END FROM T ORDER BY ID"
same "parenthesised OR under AND"   "SELECT CASE WHEN (A > 0 OR A < -5) AND S = 'Hello' THEN 'yes' ELSE 'no' END FROM T ORDER BY ID"
same "NOT over a paren group"       "SELECT CASE WHEN NOT (A > 0 OR N < 0) THEN 'neither' ELSE 'some' END FROM T ORDER BY ID"
same "UNKNOWN OR TRUE is TRUE"      "SELECT CASE WHEN A > 0 OR ID > 0 THEN 'takes' ELSE 'no' END FROM T ORDER BY ID"
same "UNKNOWN AND FALSE is FALSE"   "SELECT CASE WHEN A > 0 AND ID < 0 THEN 'x' ELSE 'else' END FROM T ORDER BY ID"
same "IIF with AND"                 "SELECT IIF(A < 0 AND N > 1, 'both', 'no') FROM T ORDER BY ID"
same "IIF with NOT and parens"      "SELECT IIF(NOT (A > 0 OR N < 0), 'neither', 'some') FROM T ORDER BY ID"

# --- typing across branches (the standing bug this gate closed) --------
same "int + scaled literal branches" "SELECT CASE WHEN A > 0 THEN 1 ELSE 0.5 END FROM T ORDER BY ID"
same "NUMERIC col + scaled literal"  "SELECT CASE WHEN A > 0 THEN N ELSE 0.5 END FROM T ORDER BY ID"
same "COALESCE int col + scaled"     "SELECT COALESCE(A, 0.5) FROM T ORDER BY ID"
same "IIF int + scaled"              "SELECT IIF(A > 0, 1, 0.25) FROM T ORDER BY ID"
same "BIGINT + int branches"         "SELECT CASE WHEN A > 0 THEN K ELSE A END FROM T ORDER BY ID"
same "NUMERIC both branches"         "SELECT CASE WHEN A > 0 THEN N ELSE -N END FROM T ORDER BY ID"
same "text branches"                 "SELECT CASE WHEN A > 0 THEN 'y' ELSE 'n' END FROM T ORDER BY ID"

# --- nesting, and the rest of the expression surface -------------------
same "CASE inside a branch"         "SELECT CASE WHEN A > 0 THEN A ELSE CASE WHEN S = 'Hello' THEN -1 ELSE -2 END END FROM T ORDER BY ID"
same "functions in cond and branches" "SELECT CASE WHEN CHAR_LENGTH(S) > 3 THEN UPPER(S) ELSE LOWER(S) END FROM T ORDER BY ID"
same "CASE under arithmetic"        "SELECT CASE WHEN A < 0 THEN 1 ELSE 0 END + 10 FROM T ORDER BY ID"
same "CASE under concatenation"     "SELECT 'r: ' || CASE WHEN A < 0 THEN 'n' ELSE 'p' END FROM T ORDER BY ID"
same "CASE inside COALESCE"         "SELECT COALESCE(CASE WHEN A > 0 THEN A END, -1) FROM T ORDER BY ID"
same "CAST of a CASE"               "SELECT CAST(CASE WHEN A < 0 THEN A ELSE 0 END AS VARCHAR(10)) FROM T ORDER BY ID"
same "SUBSTRING in a condition"     "SELECT CASE WHEN SUBSTRING(S FROM 1 FOR 1) = 'H' THEN 'h' ELSE 'x' END FROM T ORDER BY ID"
same "two CASE columns at once"     "SELECT CASE WHEN A > 0 THEN 1 ELSE 0 END, CASE S WHEN 'world' THEN 1 ELSE 0 END FROM T ORDER BY ID"

# --- headers: both forms and IIF column as CASE ------------------------
sameh "header searched CASE"        "SELECT CASE WHEN A > 0 THEN 1 ELSE 0 END FROM T WHERE ID = 1"
sameh "header simple CASE"          "SELECT CASE A WHEN 1 THEN 1 ELSE 0 END FROM T WHERE ID = 1"
sameh "header IIF is CASE"          "SELECT IIF(A > 1, 1, 0) FROM T WHERE ID = 1"

# --- an ALIAS after END: `CASE ... END <name>` (the split_alias fix) ----
# split_alias treated the CASE's own END terminator as an operand-hungry
# operator and refused to peel the trailing alias, so every aliased CASE
# raised. The value is the same with or without the alias, so `same`
# proves fc ANSWERS rather than refusing; `sameh` also pins the header.
same  "searched CASE bare alias"    "SELECT CASE WHEN A > 0 THEN 'p' ELSE 'n' END C FROM T ORDER BY ID"
same  "simple CASE bare alias"      "SELECT CASE A WHEN 42 THEN 'y' ELSE 'z' END C FROM T ORDER BY ID"
same  "numeric CASE bare alias"     "SELECT CASE WHEN A > 0 THEN 1 ELSE 0 END C FROM T ORDER BY ID"
same  "nested CASE bare alias"      "SELECT CASE WHEN A > 0 THEN CASE WHEN A > 40 THEN 'big' ELSE 'mid' END ELSE 'lo' END C FROM T ORDER BY ID"
sameh "header CASE AS alias"        "SELECT CASE WHEN A > 0 THEN 1 ELSE 0 END AS C FROM T WHERE ID = 1"
sameh "header CASE bare alias"      "SELECT CASE WHEN A > 0 THEN 1 ELSE 0 END C FROM T WHERE ID = 1"

# --- refusals: malformed forms raise, never answer ---------------------
for bad in "SELECT CASE END FROM T" \
           "SELECT CASE WHEN A > 0 END FROM T" \
           "SELECT CASE WHEN A > 0 THEN 1 FROM T" \
           "SELECT CASE A WHEN THEN 1 END FROM T"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the branch-scale alignment, pinned to raw values -----------
# 0.5 under an announced scale of -2 must travel as raw 50 (0.50), not
# raw 5 (0.05) - the exact wrong answer the standing bug produced
v=$(printf 'SET HEADING OFF;\nSELECT CASE WHEN A > 0 THEN N ELSE 0.5 END FROM T WHERE ID = 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "0.50" ]; then
    echo "OK   teeth: the scaled branch aligned to the announced scale (0.50)"
else
    echo "DIFF branch alignment gave [$v], want 0.50"; fail=1
fi

exit $fail
