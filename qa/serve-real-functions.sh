#!/bin/bash
# BUILT-IN SCALAR FUNCTIONS - the engine's SysFunction.cpp table (ABS,
# MOD, SIGN, LEFT, RIGHT, REPLACE, REVERSE, LPAD, RPAD, POSITION) and the
# parser's string intrinsics that compile to their own BLR verbs (UPPER ->
# blr_upcase, LOWER -> blr_lowcase, SUBSTRING -> blr_substring, TRIM ->
# blr_trim, CHAR_LENGTH -> blr_strlen).
#
# The content of this surface is not the happy path - it is the edges,
# each probed against the live engine BEFORE the Rust was written:
#
#   * CHAR_LENGTH counts CHARACTERS, so a CHAR(5) column counts its blank
#     padding: CHAR_LENGTH of CHAR(5) 'ab' is 5, and CHAR_LENGTH(TRIM(C))
#     is 2 - the pair proves padding travels through the functions
#   * a NUMBER under a string function renders to its text first:
#     UPPER(A) with A = -7 is '-7', CHAR_LENGTH(A) is 2
#   * SUBSTRING is a WINDOW, not a bounds check: FROM 0 FOR 3 is the
#     intersection ('He' of 'Hello' - the start eats into the length),
#     FROM 10 is empty, and only a NEGATIVE length raises
#     (isc_bad_substring_length, SQLSTATE 22011) - an error LEFT and
#     RIGHT share, because the engine routes them through SUBSTRING
#   * TRIM strips REPETITIONS of the whole <what> string:
#     TRIM(BOTH 'ab' FROM 'ababXab') is 'X'; an empty <what> is a no-op
#   * MOD rounds non-integer operands half away from zero FIRST:
#     MOD(12.50, 5) = 3 (12.50 -> 13); MOD by zero is the same
#     divide-by-zero the arithmetic surface raises (SQLSTATE 22012)
#   * POSITION's empty needle answers its start while a match could still
#     begin there: POSITION('', 'Hello', 3) = 3 but at 99 it is 0
#   * LPAD/RPAD TRUNCATE a past-length value (LPAD('Hello', 3) = 'Hel'),
#     cycle a multi-character pad, and leave a short string alone when
#     the pad is empty
#   * an un-aliased function columns under the engine's own name -
#     CHARACTER_LENGTH headers as CHAR_LENGTH, and an un-aliased IIF
#     headers as CASE (the engine parses IIF into a searched CASE)
#
# THE DIFFERENTIAL: the same isql runs the same SELECT against the engine
# and against fire-crab on the same file, and the output must match
# value for value - NULL rows included, since every one of these
# functions propagates NULL.
#
#   qa/serve-real-functions.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4483}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-functions.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  S VARCHAR(10),
  C CHAR(5),
  A INTEGER,
  N NUMERIC(9,2),
  K BIGINT,
  W COMPUTED BY (UPPER(S))
);
COMMIT;
INSERT INTO T (ID, S, C, A, N, K) VALUES (1, 'Hello', 'ab', -7, 12.50, 4000000000);
INSERT INTO T (ID, S, C, A, N, K) VALUES (2, 'wOrLd!', 'xyz', 42, -1.25, -5);
INSERT INTO T (ID, S, C, A, N, K) VALUES (3, NULL, NULL, NULL, NULL, NULL);
INSERT INTO T (ID, S, C, A, N, K) VALUES (4, '', 'a b', 0, 0.00, 0);
INSERT INTO T (ID, S, C, A, N, K) VALUES (5, '  pad  ', ' lead', 13, 2.50, 1);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fn.log 2>&1 &
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
# headers ON: the engine's output-column NAME is part of the differential
sameh() { # <label> <sql>
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

# --- case mapping and the length family --------------------------------
same "UPPER over VARCHAR"            "SELECT UPPER(S) FROM T ORDER BY ID"
same "LOWER over VARCHAR"            "SELECT LOWER(S) FROM T ORDER BY ID"
same "UPPER keeps CHAR padding"      "SELECT UPPER(C) || '.' FROM T ORDER BY ID"
same "UPPER renders a number first"  "SELECT UPPER(A) FROM T ORDER BY ID"
same "LOWER over a scaled NUMERIC"   "SELECT LOWER(N) FROM T ORDER BY ID"
same "CHAR_LENGTH over VARCHAR"      "SELECT CHAR_LENGTH(S) FROM T ORDER BY ID"
same "CHAR_LENGTH counts CHAR padding" "SELECT CHAR_LENGTH(C) FROM T ORDER BY ID"
same "CHARACTER_LENGTH synonym"      "SELECT CHARACTER_LENGTH(S) FROM T ORDER BY ID"
same "OCTET_LENGTH"                  "SELECT OCTET_LENGTH(C) FROM T ORDER BY ID"
same "CHAR_LENGTH of a number"       "SELECT CHAR_LENGTH(A) FROM T ORDER BY ID"

# --- SUBSTRING: the window semantics -----------------------------------
same "SUBSTRING FROM"                "SELECT SUBSTRING(S FROM 2) FROM T ORDER BY ID"
same "SUBSTRING FROM FOR"            "SELECT SUBSTRING(S FROM 2 FOR 3) FROM T ORDER BY ID"
same "SUBSTRING FROM 0 clips"        "SELECT SUBSTRING(S FROM 0 FOR 3) FROM T ORDER BY ID"
same "SUBSTRING negative start"      "SELECT SUBSTRING(S FROM -2 FOR 4) FROM T ORDER BY ID"
same "SUBSTRING past the end"        "SELECT SUBSTRING(S FROM 10 FOR 2) FROM T ORDER BY ID"
same "SUBSTRING FOR 0"               "SELECT SUBSTRING(S FROM 2 FOR 0) FROM T ORDER BY ID"

# --- TRIM: sides, repetitions, the empty what --------------------------
same "TRIM default both spaces"      "SELECT TRIM(S) || '.' FROM T ORDER BY ID"
same "TRIM of CHAR strips padding"   "SELECT TRIM(C) || '.' FROM T ORDER BY ID"
same "TRIM LEADING"                  "SELECT TRIM(LEADING FROM S) || '.' FROM T ORDER BY ID"
same "TRIM TRAILING a character"     "SELECT TRIM(TRAILING 'o' FROM S) FROM T ORDER BY ID"
same "TRIM strips repetitions"       "SELECT TRIM(BOTH 'ab' FROM 'ababXab') FROM T WHERE ID = 1"
same "TRIM without BOTH keyword"     "SELECT TRIM('ab' FROM 'ababXab') FROM T WHERE ID = 1"
same "TRIM with an empty what"       "SELECT TRIM('' FROM S) FROM T ORDER BY ID"

# --- LEFT / RIGHT ------------------------------------------------------
same "LEFT"                          "SELECT LEFT(S, 2) FROM T ORDER BY ID"
same "LEFT of zero"                  "SELECT LEFT(S, 0) || '.' FROM T ORDER BY ID"
same "LEFT past the end"             "SELECT LEFT(S, 99) FROM T ORDER BY ID"
same "RIGHT"                         "SELECT RIGHT(S, 3) FROM T ORDER BY ID"
same "RIGHT past the end"            "SELECT RIGHT(S, 99) FROM T ORDER BY ID"

# --- REPLACE / POSITION / REVERSE --------------------------------------
same "REPLACE"                       "SELECT REPLACE(S, 'l', 'L') FROM T ORDER BY ID"
same "REPLACE with an empty search"  "SELECT REPLACE(S, '', 'x') FROM T ORDER BY ID"
same "REPLACE removing"              "SELECT REPLACE(S, 'l', '') FROM T ORDER BY ID"
same "POSITION IN form"              "SELECT POSITION('l' IN S) FROM T ORDER BY ID"
same "POSITION comma form"           "SELECT POSITION('l', S) FROM T ORDER BY ID"
same "POSITION with a start"         "SELECT POSITION('l', S, 4) FROM T ORDER BY ID"
same "POSITION start past the end"   "SELECT POSITION('l', S, 99) FROM T ORDER BY ID"
same "POSITION empty needle"         "SELECT POSITION('', S, 3) FROM T ORDER BY ID"
same "POSITION absent"               "SELECT POSITION('zz' IN S) FROM T ORDER BY ID"
same "REVERSE"                       "SELECT REVERSE(S) FROM T ORDER BY ID"

# --- ABS / MOD / SIGN --------------------------------------------------
same "ABS of an integer"             "SELECT ABS(A) FROM T ORDER BY ID"
same "ABS keeps NUMERIC scale"       "SELECT ABS(N) FROM T ORDER BY ID"
same "ABS of a BIGINT"               "SELECT ABS(K) FROM T ORDER BY ID"
same "MOD"                           "SELECT MOD(A, 3) FROM T ORDER BY ID"
same "MOD sign rule"                 "SELECT MOD(A, -3) FROM T ORDER BY ID"
same "MOD rounds scaled operands"    "SELECT MOD(N, 5) FROM T ORDER BY ID"
same "SIGN"                          "SELECT SIGN(A) FROM T ORDER BY ID"
same "SIGN of a NUMERIC"             "SELECT SIGN(N) FROM T ORDER BY ID"

# --- LPAD / RPAD -------------------------------------------------------
same "LPAD"                          "SELECT LPAD(S, 8, '*') FROM T ORDER BY ID"
same "RPAD"                          "SELECT RPAD(S, 8, '*') FROM T ORDER BY ID"
same "LPAD truncates"                "SELECT LPAD(S, 3, '*') FROM T ORDER BY ID"
same "LPAD default pad"              "SELECT LPAD(S, 8) || '.' FROM T ORDER BY ID"
same "LPAD cycles a two-char pad"    "SELECT LPAD(S, 9, 'ab') FROM T ORDER BY ID"
same "LPAD with an empty pad"        "SELECT LPAD(S, 9, '') FROM T ORDER BY ID"
same "LPAD renders a number"         "SELECT LPAD(A, 6, '0') FROM T ORDER BY ID"

# --- nesting into the rest of the expression surface -------------------
same "functions nest with concat"    "SELECT UPPER(LEFT(S, 3)) || '-' || LOWER(RIGHT(S, 2)) FROM T ORDER BY ID"
same "CHAR_LENGTH in arithmetic"     "SELECT CHAR_LENGTH(S) + 10 FROM T ORDER BY ID"
same "ABS in arithmetic"             "SELECT ABS(A) * 2 FROM T ORDER BY ID"
same "function inside IIF condition" "SELECT IIF(CHAR_LENGTH(S) > 3, 'long', 'short') FROM T ORDER BY ID"
same "function inside COALESCE"      "SELECT COALESCE(S, LPAD('x', 3, '*')) FROM T ORDER BY ID"
same "CAST of a function"            "SELECT CAST(CHAR_LENGTH(S) AS BIGINT) FROM T ORDER BY ID"
same "function of a CAST"            "SELECT UPPER(CAST(A AS VARCHAR(5))) FROM T ORDER BY ID"
same "TRIM CHAR then count"          "SELECT CHAR_LENGTH(TRIM(C)) FROM T ORDER BY ID"
same "computed column with UPPER"    "SELECT W FROM T ORDER BY ID"

# --- headers: the engine's own output-column names ---------------------
sameh "header UPPER"                 "SELECT UPPER(S) FROM T WHERE ID = 1"
sameh "header CHAR_LENGTH from CHARACTER_LENGTH" "SELECT CHARACTER_LENGTH(S) FROM T WHERE ID = 1"
sameh "header SUBSTRING"             "SELECT SUBSTRING(S FROM 1 FOR 2) FROM T WHERE ID = 1"
sameh "header MOD"                   "SELECT MOD(A, 3) FROM T WHERE ID = 1"
sameh "header CASE for IIF"          "SELECT IIF(A > 1, 1, 0) FROM T WHERE ID = 1"

# --- errors: the engine's own codes, value for value -------------------
# a negative length raises isc_bad_substring_length (22011) with the
# offending value in the message - LEFT and RIGHT name SUBSTRING too
same "negative SUBSTRING length"     "SELECT SUBSTRING(S FROM 2 FOR -1) FROM T WHERE ID = 1"
same "negative LEFT length"          "SELECT LEFT(S, -1) FROM T WHERE ID = 1"
same "negative RIGHT length"         "SELECT RIGHT(S, -3) FROM T WHERE ID = 1"
# MOD by zero is the arithmetic exception (22012)
same "MOD by zero"                   "SELECT MOD(A, 0) FROM T WHERE ID = 1"

# --- refusals: a broken call must RAISE, never answer ------------------
for bad in "SELECT UPPER() FROM T" "SELECT UPPER(S, 2) FROM T" \
           "SELECT LEFT(S) FROM T" "SELECT MOD(A) FROM T" \
           "SELECT SUBSTRING(S, 2) FROM T" "SELECT TRIM(LEADING S) FROM T" \
           "SELECT REPLACE(S, 'a') FROM T"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: no fixed-answer constant anywhere in this surface ----------
out=$(printf 'SET HEADING OFF;\nSELECT UPPER(S), CHAR_LENGTH(S), ABS(A) FROM T;\nSELECT LPAD(S, 8, S), MOD(A, 3) FROM T;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1)
case "$out" in
    *4242*) echo "DIFF the fixed-answer constant 4242 leaked into a function result"; fail=1 ;;
    *) echo "OK   teeth: no fixed-answer constant in any function result" ;;
esac
# ...and the session survives a refusal mid-script: the statements after
# a broken call still answer on the same connection
after=$(printf 'SET HEADING OFF;\nSELECT UPPER() FROM T;\nSELECT ABS(A) FROM T WHERE ID = 1;\nSELECT CHAR_LENGTH(S) FROM T WHERE ID = 1;\n' |
        "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 |
        grep -cE '^ *[0-9]+ *$')
if [ "$after" -ge 2 ]; then
    echo "OK   teeth: the session survived a refused call and answered $after more rows"
else
    echo "DIFF the session answered $after rows after a refused call, want 2"; fail=1
fi

exit $fail
