#!/bin/bash
# TEXT COMPARISONS in PSQL conditions - `IF (B = 'x')` and its family,
# found refused by the SELECT INTO gate's first draft.
#
# The laws, each measured against the engine before conversion:
#
#   * text comparison is PAD SPACE: 'x' = 'x ' is TRUE - both sides are
#     space-padded to the longer and the bytes decide;
#   * ...and CASE-SENSITIVE under charset NONE: 'x' = 'X' is not;
#   * ordering (<, <=, >, >=) is byte order with the same padding;
#   * a NULL operand makes the comparison UNKNOWN - the IF skips;
#   * variable-vs-literal and variable-vs-variable both work, and text
#     conditions mix freely with integer ones under AND/OR;
#   * an embedded UPDATE's WHERE takes a text comparison too (it renders
#     through the ordinary planner).
#
# THE STORED-BLR BOUNDARY: a text literal has no probed BLR shape, so a
# body carrying one is INTERPRETED, never emitted (the emitter guard is
# body_has_uninterpretable_blr), and a CHECK constraint with a text
# comparison refuses exactly as it always did (the CHECK surface is
# int-only by rank).
#
#   qa/serve-real-psqltext.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4727}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-psqltext-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

mkdb() {
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V VARCHAR(10));
CREATE EXCEPTION E_T 'tru';
COMMIT;
INSERT INTO T VALUES (1, 'one');
INSERT INTO T VALUES (2, 'two');
COMMIT;
EOF
}
EDB="$D/fc-ptx-e.fdb"
FDB="$D/fc-ptx-f.fdb"
rm -f "$EDB" "$FDB"
mkdb "localhost:$EDB"
mkdb "$FDB"
chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
E="localhost:$EDB"
F="127.0.0.1/$PORT:$FDB"
blk() { # <conn> <body>
    printf 'SET TERM ^ ;\nEXECUTE BLOCK AS\nDECLARE A INTEGER;\nDECLARE B VARCHAR(10);\nDECLARE C VARCHAR(10);\nBEGIN\n%s\nEND^\nSET TERM ; ^\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
both() { check "$1" "$(blk "$F" "$2")" "$(blk "$E" "$2")"; }

both "equal text raises the marker" "B='x'; IF (B = 'x') THEN EXCEPTION E_T;"
both "PAD SPACE: 'x' = 'x ' is TRUE" "B='x'; IF (B = 'x ') THEN EXCEPTION E_T;"
both "...and case-sensitive under NONE: 'x' = 'X' is not" "B='x'; IF (B = 'X') THEN EXCEPTION E_T;"
both "ordering is padded byte order" "B='abc'; C='abd'; IF (B < C) THEN EXCEPTION E_T;"
both "...and >= holds on equality" "B='ab'; IF (B >= 'ab') THEN EXCEPTION E_T;"
both "variable vs variable" "B='q'; C='q'; IF (B = C) THEN EXCEPTION E_T;"
both "<> on different text" "B='x'; IF (B <> 'y') THEN EXCEPTION E_T;"
both "a NULL operand is UNKNOWN - the IF skips" "IF (B = '') THEN EXCEPTION E_T;"
both "text and integer conditions mix under AND" "A=1; B='x'; IF (A = 1 AND B = 'x') THEN EXCEPTION E_T;"
both "an embedded UPDATE's WHERE takes text" \
    "UPDATE T SET ID = 9 WHERE V = 'one'; IF (ROW_COUNT = 1) THEN EXCEPTION E_T;"
both "the doubled-quote escape survives" "B='it''s'; IF (B = 'it''s') THEN EXCEPTION E_T;"

# --- NULL is a value the keyword can say ----------------------------------------
# (the increment after the text one: B = NULL used to refuse the body)
both "the NULL keyword assigns NULL to a text variable" \
    "B='x'; B=NULL; IF (B IS NULL) THEN EXCEPTION E_T;"
both "...and to an integer variable" \
    "A=5; A=NULL; IF (A IS NULL) THEN EXCEPTION E_T;"
both "comparing WITH the NULL keyword is UNKNOWN - the IF skips" \
    "B='x'; IF (B = NULL) THEN EXCEPTION E_T;"
both "NULL propagates through arithmetic" \
    "A=NULL; A=A+1; IF (A IS NULL) THEN EXCEPTION E_T;"

# --- BIGINT literals (the increment after NULL) --------------------------------
# ETok::Num was an i32 and 3000000000 refused the whole body; the
# narrowest literal that holds the value keeps every stored shape's
# exact BLR bytes, and only an out-of-range one takes blr_int64
bl() { # <conn> <body> - BIGINT declare instead of the default frame
    printf 'SET TERM ^ ;\nEXECUTE BLOCK AS\nDECLARE G BIGINT;\nBEGIN\n%s\nEND^\nSET TERM ; ^\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
bboth() { check "$1" "$(bl "$F" "$2")" "$(bl "$E" "$2")"; }
bboth "a BIGINT literal assigns and compares" \
    "G = 3000000000; IF (G = 3000000000) THEN EXCEPTION E_T;"
bboth "...and negative" "G = -3000000000; IF (G < 0) THEN EXCEPTION E_T;"
bboth "...and through arithmetic" \
    "G = 9000000000 + 1; IF (G > 9000000000) THEN EXCEPTION E_T;"

# --- the stored-BLR boundary stays closed --------------------------------------
out=$(printf "CREATE TABLE TCX (V VARCHAR(5) CHECK (V = 'x'));\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$F" 2>&1 | head -1)
check "boundary: a CHECK with a text comparison still refuses" \
    "$out" "Statement failed, SQLSTATE = 42000"

echo "ran $ran checks"
exit $fail
