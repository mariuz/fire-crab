#!/bin/bash
# RUNTIME ERRORS AS THINGS A BODY CAN CATCH.
#
# `qa/serve-real-exceptions.sh` covers what a body RAISES on purpose.
# This is the other half: what goes wrong BY ITSELF - a division by
# zero, an arithmetic overflow - and the three condition forms that name
# such errors. All three used to be refused whole, and a division by
# zero was a REFUSAL rather than an error, which no handler can catch.
#
# The two contrasts are the interesting part, and they are opposite ways
# round:
#
#   * `WHEN GDSCODE` matches the FIRST code of the vector AND NO OTHER
#     (StmtNodes.cpp:744). A division by zero posts `isc_arith_except`
#     then `isc_exception_integer_divide_by_zero`, so `WHEN GDSCODE
#     arith_except` catches it and `WHEN GDSCODE
#     exception_integer_divide_by_zero` DOES NOT.
#   * `WHEN SQLSTATE` matches the state DERIVED FROM THE WHOLE VECTOR
#     (`fb_sqlstate`, gds.cpp:2464), which skips isc_random/isc_sqlerr
#     and keeps scanning past the general 22000/42000/HY000 for
#     something specific. So the same error is `'22012'` - and
#     `'22000'`, the first code's own state, does NOT catch it.
#
# A server that gave every error one identity would get exactly one of
# those two right.
#
#   qa/serve-real-psqlerrors.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4704}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-psqlerrors.fdb"
LOG="/tmp/fc-serve-psqlerrors-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE EXCEPTION E_MINE 'mine happened';
COMMIT;
SET TERM ^;
/* caught by each condition form */
CREATE PROCEDURE D_ANY RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN ANY DO N=-1; END^
CREATE PROCEDURE D_SQLCODE RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN SQLCODE -802 DO N=-2; END^
CREATE PROCEDURE D_GDS RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN GDSCODE arith_except DO N=-3; END^
CREATE PROCEDURE D_STATE RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN SQLSTATE '22012' DO N=-5; END^
/* ...and the two that must NOT catch it */
CREATE PROCEDURE D_GDSDEEP RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN GDSCODE exception_integer_divide_by_zero DO N=-4; END^
CREATE PROCEDURE D_STATEGEN RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN SQLSTATE '22000' DO N=-6; END^
/* a USER exception has an identity in the same three shapes */
CREATE PROCEDURE X_GDS RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN GDSCODE except DO N=-7; END^
CREATE PROCEDURE X_SQLCODE RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN SQLCODE -836 DO N=-8; END^
CREATE PROCEDURE X_STATE RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN SQLSTATE 'HY000' DO N=-9; END^
/* uncaught, and re-raised */
CREATE PROCEDURE D_UNCAUGHT RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; END^
CREATE PROCEDURE D_RERAISE RETURNS (N INTEGER) AS DECLARE Z INTEGER;
BEGIN Z=0; N=1/Z; WHEN ANY DO EXCEPTION; END^
/* An overflow is the same mechanism, and it used to answer NULL.
   The overflow is reached by MULTIPLYING UP from small literals rather
   than writing 9223372036854775807: this server's expression tree holds
   a literal as an i32 (`Expr::IntLiteral`), so a body naming a BIGINT
   constant is outside its surface - a gap of its own, and widening it
   changes BLR encoding and type ranking, so it is not a drive-by. */
CREATE PROCEDURE O_CAUGHT RETURNS (N BIGINT) AS DECLARE B BIGINT;
BEGIN B=1; WHILE (B > 0) DO B = B * 3; N=B; WHEN SQLSTATE '22003' DO N=-10; END^
CREATE PROCEDURE O_ANY RETURNS (N BIGINT) AS DECLARE B BIGINT;
BEGIN B=1; WHILE (B > 0) DO B = B * 3; N=B; WHEN ANY DO N=-11; END^
SET TERM ;^
COMMIT;
EOF
chmod 666 "$DB"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

run() { # <conn> <sql>
    printf '%s\n' "$2" | timeout 30 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}

both() { # <label> <proc>
    local eng fc
    eng=$(run "$DB" "SET HEADING OFF;
EXECUTE PROCEDURE $2;")
    fc=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE $2;")
    ran=$((ran + 1))
    if [ "$eng" = "$fc" ]; then echo "OK   $1 [$eng]"
    else echo "DIFF $1"; echo "     engine: $eng"; echo "     fc:     $fc"; fail=1; fi
}

# --- 1. a division by zero is CATCHABLE ---------------------------------
both "WHEN ANY catches a division by zero" D_ANY
both "WHEN SQLCODE -802 catches it - the first code's SQLCODE" D_SQLCODE
both "WHEN GDSCODE arith_except catches it - the first code" D_GDS
both "WHEN SQLSTATE '22012' catches it - the DERIVED state" D_STATE

# --- 2. ...and the two conditions that must NOT catch it -----------------
both "WHEN GDSCODE exception_integer_divide_by_zero does NOT (second code)" D_GDSDEEP
both "WHEN SQLSTATE '22000' does NOT (the derivation looks past it)" D_STATEGEN

# --- 3. a user exception has the same three identities -------------------
both "WHEN GDSCODE except catches a raise" X_GDS
both "WHEN SQLCODE -836 catches it" X_SQLCODE
both "WHEN SQLSTATE 'HY000' catches it" X_STATE

# --- 4. uncaught, and re-raised -----------------------------------------
both "an uncaught division by zero, error text and position" D_UNCAUGHT
both "a handler may re-raise a runtime error with a bare EXCEPTION;" D_RERAISE

# --- 5. an overflow is an ERROR, not a NULL ------------------------------
# This answered NULL - the one thing a converted engine may never do -
# because the evaluator treated a checked_add that did not fit as an
# absent value.
both "an arithmetic overflow is catchable by its SQLSTATE" O_CAUGHT
both "...and by WHEN ANY" O_ANY

# --- 6. TEETH ------------------------------------------------------------
# Every check above compares two servers, so a shared refusal would read
# as agreement. The answers -1..-11 can only come from a handler that
# ran, and the log must show the errors reaching the wire rather than
# being refused.
answers=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE D_ANY;
EXECUTE PROCEDURE D_GDS;
EXECUTE PROCEDURE D_STATE;
EXECUTE PROCEDURE X_SQLCODE;
EXECUTE PROCEDURE O_ANY;")
ran=$((ran + 1))
if [ "$answers" = "-1|-3|-5|-8|-11|" ]; then
    echo "OK   teeth: every condition form ran a handler and answered"
else
    echo "DIFF teeth: handlers did not answer [$answers]"; fail=1
fi
refusals=$(grep -c "does not interpret" "$LOG")
ran=$((ran + 1))
if [ "$refusals" -eq 0 ]; then
    echo "OK   teeth: no body was refused - these are errors now, not refusals"
else
    echo "DIFF teeth: $refusals bodies were still refused"; fail=1
fi

echo "ran $ran checks"
exit $fail
