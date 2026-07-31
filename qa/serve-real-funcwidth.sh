#!/bin/bash
# THE DECLARED WIDTH OF A TEXT FUNCTION'S RESULT, compared through the
# ENGINE'S OWN TOOL: the same isql, the same statement, run against
# fire-crab and against the real engine over the same database file, and
# the output compared VERBATIM.
#
# Why isql rather than the usual driver twin: a declared width is not a
# value, so a driver that hands back a JavaScript string shows nothing.
# isql lays out its columns FROM THE DESCRIBE, so the width is visible in
# the rendered text - and it was very visible indeed. fire-crab announced
# VARCHAR(32765) for every text expression it could not size, so
#
#   SELECT UPPER(V) FROM T
#
# printed a 32765-wide column where the engine prints a 6-wide one. The
# values agreed; the layout did not, in the engine's own client.
#
# The rules, each probed with `SET SQLDA_DISPLAY ON` before any code:
#
#   UPPER / LOWER          the ARGUMENT's form AND width - so
#                          UPPER(<CHAR(6)>) is CHAR(6), and pads
#   TRIM                   VARYING, the argument's width
#   LEFT / RIGHT / REVERSE VARYING, the SOURCE's width - NOT the count,
#                          which is the surprise: LEFT(V, 3) over a
#                          VARCHAR(6) is VARYING(6), not VARYING(3)
#   SUBSTRING              VARYING; the literal FOR length when there is
#                          one, else the source's width
#   LPAD / RPAD            VARYING at the literal pad length
#   a || b                 VARYING, the SUM of the two widths
#
# REPLACE is deliberately left unsized: its bound is some function of the
# search and replacement lengths (VARCHAR(6) with 'a' -> 'bb' answers
# VARYING(12)) and one probe is not a law. It keeps the catch-all
# declaration, and this gate does not pretend otherwise.
#
#   qa/serve-real-funcwidth.sh [port]
#
# Builds one scratch database and points both servers at it - the file is
# read-only here, so one copy is enough and the comparison cannot drift
# on data.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4550}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-fwidth.fdb"

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V VARCHAR(6), C CHAR(6), W VARCHAR(10),
                SM SMALLINT, BG BIGINT);
COMMIT;
INSERT INTO T VALUES (1, 'ab', 'ab', 'abc', 7, 9000000000);
INSERT INTO T VALUES (2, 'abcdef', 'abcdef', 'abcdefghij', -7, -9000000000);
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL);
COMMIT;
EOF
chmod 666 "$DB"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-funcwidth.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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

# the HEADER and the separator line are kept: they ARE the width
both() { # <label> <select body>
    ran=$((ran + 1))
    a=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" <<EOF 2>&1
$1;
EOF
)
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" <<EOF 2>&1
$1;
EOF
)
    if [ "$a" = "$b" ]; then
        echo "OK   ${1:0:60} [$(printf '%s' "$b" | sed -n '2p' | wc -c) cols]"
    else
        echo "DIFF ${1:0:60}"
        echo "     fcwire: $(printf '%s' "$a" | sed -n '2p' | cut -c1-40)|"
        echo "     engine: $(printf '%s' "$b" | sed -n '2p' | cut -c1-40)|"
        fail=1
    fi
}

# --- 0. the controls: a plain column of each form ---------------------
both "SELECT V FROM T ORDER BY ID"
both "SELECT C FROM T ORDER BY ID"

# --- 1. UPPER and LOWER keep the argument's FORM ----------------------
both "SELECT UPPER(V) FROM T ORDER BY ID"
both "SELECT UPPER(C) FROM T ORDER BY ID"
both "SELECT LOWER(V) FROM T ORDER BY ID"
both "SELECT LOWER(C) FROM T ORDER BY ID"

# --- 2. TRIM is VARYING at the argument's width -----------------------
both "SELECT TRIM(C) FROM T ORDER BY ID"
both "SELECT TRIM(V) FROM T ORDER BY ID"
both "SELECT TRIM(LEADING FROM C) FROM T ORDER BY ID"

# --- 3. LEFT/RIGHT/REVERSE take the SOURCE's width, not the count -----
both "SELECT LEFT(V, 3) FROM T ORDER BY ID"
both "SELECT LEFT(W, 2) FROM T ORDER BY ID"
both "SELECT RIGHT(C, 2) FROM T ORDER BY ID"
both "SELECT REVERSE(C) FROM T ORDER BY ID"
both "SELECT REVERSE(W) FROM T ORDER BY ID"

# --- 4. SUBSTRING: the FOR length, or the source's width --------------
both "SELECT SUBSTRING(C FROM 1 FOR 3) FROM T ORDER BY ID"
both "SELECT SUBSTRING(W FROM 2 FOR 4) FROM T ORDER BY ID"
both "SELECT SUBSTRING(V FROM 2) FROM T ORDER BY ID"
both "SELECT SUBSTRING(W FROM 3) FROM T ORDER BY ID"

# --- 5. LPAD/RPAD take their pad length -------------------------------
both "SELECT LPAD(V, 9) FROM T ORDER BY ID"
both "SELECT RPAD(V, 8) FROM T ORDER BY ID"
both "SELECT LPAD(W, 12) FROM T ORDER BY ID"

# --- 6. CONCATENATION sums its operands -------------------------------
both "SELECT C || V FROM T ORDER BY ID"
both "SELECT V || W FROM T ORDER BY ID"
both "SELECT C || 'x' FROM T ORDER BY ID"
both "SELECT V || W || C FROM T ORDER BY ID"
both "SELECT UPPER(V) || TRIM(C) FROM T ORDER BY ID"

# --- 7. the conditionals, whose widths the previous increment set -----
both "SELECT CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END FROM T ORDER BY ID"
both "SELECT COALESCE(V, 'zzzzzzzzzz') FROM T ORDER BY ID"
both "SELECT CAST(V AS CHAR(9)) FROM T ORDER BY ID"
both "SELECT 'abc' FROM T ORDER BY ID"

# --- 8. a NUMERIC function's declared width ---------------------------
# The engine does NOT announce every integer result as BIGINT. It has a
# width per function, and the earlier version of this gate had to soften
# a check because of it - that check is restored at the bottom.
#
#   SIGN                       SHORT, whatever its argument
#   CHAR_LENGTH / OCTET_LENGTH
#   / POSITION                 LONG, always
#   MOD                        the FIRST operand's own width
#   ABS                        ONE STEP WIDER than its source
#
# Ordinary ARITHMETIC is INT64 on both sides (probed: ID + 1, S + S and
# ID * 2 all announce INT64), so the widening fire-crab does there is
# what the engine does too - the deviation was only ever in the
# functions.
both "SELECT SIGN(ID) FROM T ORDER BY ID"
both "SELECT SIGN(SM) FROM T ORDER BY ID"
both "SELECT SIGN(BG) FROM T ORDER BY ID"
both "SELECT MOD(ID, 3) FROM T ORDER BY ID"
both "SELECT MOD(SM, 3) FROM T ORDER BY ID"
both "SELECT MOD(BG, 3) FROM T ORDER BY ID"
both "SELECT ABS(ID) FROM T ORDER BY ID"
both "SELECT ABS(SM) FROM T ORDER BY ID"
both "SELECT CHAR_LENGTH(V) FROM T ORDER BY ID"
both "SELECT OCTET_LENGTH(C) FROM T ORDER BY ID"
both "SELECT POSITION('a' IN V) FROM T ORDER BY ID"
# ordinary arithmetic, which must NOT narrow
both "SELECT ID + 1 FROM T ORDER BY ID"
both "SELECT SM + SM FROM T ORDER BY ID"
both "SELECT ID * 2 FROM T ORDER BY ID"
both "SELECT ID + BG FROM T ORDER BY ID"

# --- 9. a mixture, text and numeric together --------------------------
both "SELECT ID, V, UPPER(C), LEFT(W, 4) FROM T ORDER BY ID"
# the check the previous increment had to soften, restored in full
both "SELECT ID, ID + 1, CHAR_LENGTH(V) FROM T ORDER BY ID"
both "SELECT SIGN(ID), UPPER(V), MOD(ID, 3), TRIM(C) FROM T ORDER BY ID"

rm -f "$DB"
if [ "$ran" -lt 48 ]; then
    echo "DIFF only $ran checks ran (expected at least 48) - did one silently skip?"
    fail=1
fi
exit $fail
