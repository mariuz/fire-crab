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
-- THE DATABASE HAS NO DEFAULT CHARACTER SET, so V / C / W are all NONE -
-- byte carriers, one byte per character. That is why the computed-length
-- pad's wrong width survived this gate for so long: every cell here sized
-- at one byte per character, where the defect doubled a MULTI-byte one.
-- U8 and OC give the other half of the law.
CREATE TABLE T (ID INTEGER, V VARCHAR(6), C CHAR(6), W VARCHAR(10),
                SM SMALLINT, BG BIGINT,
                U8 VARCHAR(6) CHARACTER SET UTF8,
                OC VARCHAR(6) CHARACTER SET OCTETS,
                W1 VARCHAR(6) CHARACTER SET WIN1252);
COMMIT;
INSERT INTO T VALUES (1, 'ab', 'ab', 'abc', 7, 9000000000, 'ab', _OCTETS x'4142', 'ab');
INSERT INTO T VALUES (2, 'abcdef', 'abcdef', 'abcdefghij', -7, -9000000000, 'abcdef', _OCTETS x'414243', 'abcdef');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
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

# --- 5b. A COMPUTED pad length falls back to the widest VARCHAR -------
# A pad whose length is not a literal cannot be sized statically, so the
# width falls back to the widest VARCHAR the result's charset admits. The
# VALUES always agree, so only a describe comparison sees any of this -
# and section 5 above tests pad lengths that are all LITERALS, which is
# how the fallback's defects survived here for so long.
#
# STALE CLAIM CORRECTED (2026-09-18). This header used to say fire-crab
# "announced exactly TWICE the engine's width on every computed pad:
# 65533 against 32765". That is FALSE for the attachment these very cells
# run under. Measured across four attachments and four source charsets:
# under isql's default NONE attachment the engine announces 65533 (65532
# for a UTF8 source) and fire-crab agrees - which is exactly why the
# cells below pass. The 32765 ceiling belongs to a REAL attachment only.
#
# The blanket "the engine's limit is 32765" reading is not harmless: it
# is what led an earlier attempt to lower the ceiling UNCONDITIONALLY,
# which regressed every NONE-attachment cell (exprshape 54/0 -> 50/5) and
# had to be reverted. The attachment-conditional law, and the four-way
# matrix that pins it, are in section 5d below - plan from there.
both "SELECT LPAD(V, ID) FROM T ORDER BY ID"
both "SELECT RPAD(V, ID) FROM T ORDER BY ID"
both "SELECT LPAD(C, ID) FROM T ORDER BY ID"
both "SELECT LPAD(W, ID) FROM T ORDER BY ID"
both "SELECT LPAD(OC, ID) FROM T ORDER BY ID"
both "SELECT LPAD(U8, ID) FROM T ORDER BY ID"
both "SELECT RPAD(U8, ID) FROM T ORDER BY ID"
# the length need not be a bare column: any shape that is not a literal
# takes the same fallback
both "SELECT LPAD(U8, ID + 1) FROM T ORDER BY ID"
both "SELECT LPAD(U8, CAST(ID AS SMALLINT)) FROM T ORDER BY ID"
both "SELECT LPAD(V, ID, '*') FROM T ORDER BY ID"

# --- 5c. RECORDED: a folded scalar subquery sizes from the DATA --------
# A non-correlated scalar subquery is evaluated at PREPARE and spliced
# into the statement text as a literal, so by the time the width is
# computed it is indistinguishable from one the user wrote - and the pad
# is sized at that value. The announce therefore depends on the ROWS:
# measured over a two-row table, `LPAD(<utf8>, (SELECT MAX(ID) ...))`
# announced len 28 for MAX 7 and len 4 for MIN 1, where the engine keeps
# it dynamic at 32764. The same statement describes differently against
# different data, which is the one thing a describe must never do.
#
# Left RECORDED rather than fixed: the fold is a TEXT rewrite, so undoing
# it for this one position needs the argument's place recovered from the
# pre-fold text, and widening every subquery-bearing item instead would be
# wrong - a whole-item scalar subquery announces its column's own type and
# agrees today. This cell passes only while they still differ.
differs() { # <label> <select body>
    ran=$((ran + 1))
    local a b
    a=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" <<EOF 2>&1
$2;
EOF
)
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" <<EOF 2>&1
$2;
EOF
)
    if [ "$a" = "$b" ]; then
        echo "DIFF $1: the recorded divergence is GONE - promote this cell to both()"
        fail=1
    elif [ -z "$b" ]; then
        echo "DIFF $1: VACUOUS - the engine answered nothing"
        fail=1
    else
        echo "OK   $1: recorded (still differs)"
    fi
}
differs "a folded subquery sizes the pad from the data" \
    "SELECT LPAD(U8, (SELECT MAX(ID) FROM T)) FROM T ORDER BY ID"

# --- 5d. THE COMPUTED-PAD CEILING IS THE ATTACHMENT'S -----------------
# THE DIMENSION THIS GATE NEVER HAD. Every cell above runs under isql's
# default attachment, which is NONE - and the header already says why
# that hid a defect once. It hid a second one: the computed-pad fallback
# is the only expression that reaches the width sentinel, and its ceiling
# DEPENDS ON THE ATTACHMENT. Measured engine-side over four sources x
# four attachments, the law is
#
#     chars = 65533 / bpc(SOURCE charset)
#     bytes = min(chars, ceiling / bpc(OUT charset)) * bpc(OUT)
#     ceiling = 65533 under a NONE attachment, 32765 under any REAL one
#
# so `LPAD(<utf8>, ID)` is 65532 / 32764 / 16383 / 16383 across NONE /
# UTF8 / WIN1252 / ISO8859_1 while a NONE source is 65533 / 32765 /
# 32765 / 32765. fire-crab announced 65533 (or 65532) everywhere.
#
# ISO8859_1 is in the list ON PURPOSE: an earlier attempt at this bullet
# measured ONE attachment, generalised, and had to be reverted. A fourth
# attachment is what turns "UTF8 and WIN1252 behave so" into "any real
# attachment behaves so".
bothch() { # <sql> - the DESCRIBE under each attachment
    local sql="$1" ch a b
    for ch in NONE UTF8 WIN1252 ISO8859_1; do
        ran=$((ran + 1))
        a=$("$ISQL" -q -b -ch "$ch" -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" <<EOF 2>&1 | grep -aE '^ *01: sqltype' | sed 's/  */ /g'
SET SQLDA_DISPLAY ON;
SET HEADING OFF;
$sql;
EOF
)
        b=$("$ISQL" -q -b -ch "$ch" -user "$U" -pas "$P" "$DB" <<EOF 2>&1 | grep -aE '^ *01: sqltype' | sed 's/  */ /g'
SET SQLDA_DISPLAY ON;
SET HEADING OFF;
$sql;
EOF
)
        if [ "$a" = "$b" ] && [ -n "$b" ]; then
            echo "OK   [-ch $ch] ${sql:0:46}: $b"
        else
            echo "DIFF [-ch $ch] ${sql:0:46}"
            echo "     fcwire: $a"
            echo "     engine: $b"
            fail=1
        fi
    done
}
valch() { # <sql> - the VALUE under each attachment: a width fix must move none
    local sql="$1" ch a b
    for ch in NONE UTF8 WIN1252 ISO8859_1; do
        ran=$((ran + 1))
        a=$("$ISQL" -q -b -ch "$ch" -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" <<EOF 2>&1
SET LIST ON;
$sql;
EOF
)
        b=$("$ISQL" -q -b -ch "$ch" -user "$U" -pas "$P" "$DB" <<EOF 2>&1
SET LIST ON;
$sql;
EOF
)
        if [ "$a" = "$b" ] && [ -n "$b" ]; then
            echo "OK   [-ch $ch] value ${sql:0:40}"
        else
            echo "DIFF [-ch $ch] value ${sql:0:40}"
            echo "     fcwire: $(printf '%s' "$a" | paste -sd'|' | cut -c1-70)"
            echo "     engine: $(printf '%s' "$b" | paste -sd'|' | cut -c1-70)"
            fail=1
        fi
    done
}
# the dynamic pad, one cell per SOURCE charset
bothch "SELECT LPAD(U8, ID) FROM T WHERE ID = 1"
bothch "SELECT RPAD(U8, ID) FROM T WHERE ID = 1"
bothch "SELECT LPAD(V, ID) FROM T WHERE ID = 1"
bothch "SELECT LPAD(W1, ID) FROM T WHERE ID = 1"
bothch "SELECT LPAD(OC, ID) FROM T WHERE ID = 1"
bothch "SELECT LPAD(C, ID) FROM T WHERE ID = 1"
bothch "SELECT LPAD(U8, ID + 1) FROM T WHERE ID = 1"
# the controls that must NOT move: a LITERAL pad is sized from the
# literal, and the statically sized expressions never reach the sentinel
# at all - their widths sit orders below ceiling/bpc, which is what
# bounds this change's blast radius.
bothch "SELECT LPAD(U8, 7) FROM T WHERE ID = 1"
bothch "SELECT UPPER(U8) FROM T WHERE ID = 1"
bothch "SELECT U8 || W1 FROM T WHERE ID = 1"
bothch "SELECT REPLACE(U8, 'a', 'bb') FROM T WHERE ID = 1"
bothch "SELECT SUBSTRING(U8 FROM ID) FROM T WHERE ID = 1"
# and the VALUES, which a width change must leave exactly where they were
valch "SELECT LPAD(U8, ID) AS R, OCTET_LENGTH(LPAD(U8, ID)) AS L FROM T WHERE ID = 2"
valch "SELECT LPAD(V, ID) AS R, OCTET_LENGTH(LPAD(V, ID)) AS L FROM T WHERE ID = 2"

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
if [ "$ran" -lt 115 ]; then
    echo "DIFF only $ran checks ran (expected at least 115) - did one silently skip?"
    fail=1
fi
exit $fail
