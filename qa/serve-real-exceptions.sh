#!/bin/bash
# EXCEPTIONS IN PSQL: CATCHING THEM, RE-RAISING THEM, AND WHAT REACHES
# THE CLIENT WHEN NOBODY CATCHES.
#
# `WHEN ANY DO` was the whole of it before this: a handler with a
# CONDITION was refused, a bare `EXCEPTION;` was refused, and an
# exception nobody caught came out as a generic Dynamic SQL Error -
# which is the one answer a client cannot act on, because it cannot tell
# "your data raised E_MINE" from "this server could not run that".
#
# So the interesting half of this gate is the ERROR TEXT, compared line
# for line against the engine's:
#
#   Statement failed, SQLSTATE = HY000
#   exception 1                                 <- isc_except + the NUMBER
#   -"PUBLIC"."E_MINE"                          <- isc_random + quoted name
#   -mine happened                              <- isc_random + the message
#   -At procedure "PUBLIC"."P" line: 2, col: 12 <- isc_stack_trace, one
#                                                  PER RAISE POINT
#
# That last item is why this gate creates the same body under three
# different DDL shapes. **The engine counts the CREATE PROCEDURE text,
# and the catalog stores only the body**: the identical body reports
# line 2 under a one-line header, line 6 under a five-line one, and line
# 1 col 59 when the whole statement was one line. fire-crab recovers the
# difference from the procedure's own `RDB$DEBUG_INFO` - the format it
# already writes for its own triggers - and a gate that only ever used
# one header shape would pass with the offset hard-coded.
#
#   qa/serve-real-exceptions.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4701}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-exceptions.fdb"
LOG="/tmp/fc-serve-exceptions-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE EXCEPTION E_MINE 'mine happened';
CREATE EXCEPTION E_OTHER 'the other one';
COMMIT;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY);
COMMIT;
SET TERM ^;
/* the handler forms */
CREATE PROCEDURE P_ANY RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN ANY DO N=-1; END^
CREATE PROCEDURE P_NAMED RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN EXCEPTION E_MINE DO N=-2; END^
CREATE PROCEDURE P_WRONGNAME RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN EXCEPTION E_OTHER DO N=-3; END^
/* WHICH handler runs, in each shape that distinguishes a rule */
CREATE PROCEDURE P_NAMEDFIRST RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN EXCEPTION E_MINE DO N=-4; WHEN EXCEPTION E_OTHER DO N=-5; END^
CREATE PROCEDURE P_ANYAFTER RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN EXCEPTION E_MINE DO N=-4; WHEN ANY DO N=-5; END^
CREATE PROCEDURE P_ANYBEFORE RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN ANY DO N=-5; WHEN EXCEPTION E_MINE DO N=-4; END^
CREATE PROCEDURE P_MIDDLE RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE;
  WHEN EXCEPTION E_OTHER DO N=-6;
  WHEN EXCEPTION E_MINE DO N=-7;
  WHEN EXCEPTION E_OTHER DO N=-8;
END^
CREATE PROCEDURE P_TWOANY RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN ANY DO N=-88; WHEN ANY DO N=-99; END^
/* uncaught, and re-raised */
CREATE PROCEDURE P_UNCAUGHT RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; END^
CREATE PROCEDURE P_RERAISE RETURNS (N INTEGER) AS
BEGIN N=1; EXCEPTION E_MINE; WHEN ANY DO EXCEPTION; END^
/* nesting: the inner block's handler catches, the outer never sees it */
CREATE PROCEDURE P_NESTED RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  BEGIN
    EXCEPTION E_MINE;
    WHEN EXCEPTION E_MINE DO N = 1;
  END
  N = N + 10;
  WHEN ANY DO N = -6;
END^
/* ...and one where the inner re-raises into the outer */
CREATE PROCEDURE P_NESTRAISE RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  BEGIN
    EXCEPTION E_MINE;
    WHEN ANY DO EXCEPTION;
  END
  N = N + 10;
  WHEN EXCEPTION E_MINE DO N = -7;
END^
/* the SAME body under three DDL shapes - the At-procedure item counts
   the DDL, not the body */
CREATE PROCEDURE P_ONELINE RETURNS (N INTEGER) AS BEGIN N=1; EXCEPTION E_MINE; END^
CREATE PROCEDURE P_TALLHEAD

   RETURNS (N INTEGER)

AS
BEGIN N=1; EXCEPTION E_MINE; END^
/* a raise AFTER a write: the body is all-or-nothing */
/* NB the column list is not decoration: an INSERT without one is
   outside this server's PSQL surface, which is a gap of its own and
   nothing to do with exceptions */
CREATE PROCEDURE P_WROTE RETURNS (N INTEGER) AS
BEGIN
  INSERT INTO T (ID) VALUES (1);
  EXCEPTION E_MINE;
END^
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
    printf '%s\n' "$2" | "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}

both() { # <label> <sql>
    local eng fc
    eng=$(run "$DB" "$2")
    fc=$(run "127.0.0.1/$PORT:$DB" "$2")
    ran=$((ran + 1))
    if [ "$eng" = "$fc" ]; then echo "OK   $1 [$eng]"
    else echo "DIFF $1"; echo "     engine: $eng"; echo "     fc:     $fc"; fail=1; fi
}

# --- 1. the handler forms ------------------------------------------------
both "WHEN ANY catches a raise" "SET HEADING OFF;
EXECUTE PROCEDURE P_ANY;"
both "WHEN EXCEPTION <name> catches its own" "SET HEADING OFF;
EXECUTE PROCEDURE P_NAMED;"
both "...and does NOT catch a different one" "SET HEADING OFF;
EXECUTE PROCEDURE P_WRONGNAME;"
# WHICH HANDLER RUNS. The rule is not the one the engine's own loop
# over a block's handlers suggests (StmtNodes.cpp:604 takes the first
# whose conditions match, in list order) - `WHEN ANY` beats a named
# handler that matches AND comes first, so the list that loop walks is
# evidently not the source-order one. Each shape below pins one part of
# what the engine actually does.
both "with no WHEN ANY, the first matching named handler wins" "SET HEADING OFF;
EXECUTE PROCEDURE P_NAMEDFIRST;"
both "...and a matching one in the MIDDLE still wins" "SET HEADING OFF;
EXECUTE PROCEDURE P_MIDDLE;"
both "a WHEN ANY AFTER a matching named handler beats it" "SET HEADING OFF;
EXECUTE PROCEDURE P_ANYAFTER;"
both "...and so does one before it" "SET HEADING OFF;
EXECUTE PROCEDURE P_ANYBEFORE;"
both "among several WHEN ANY, the LAST one runs" "SET HEADING OFF;
EXECUTE PROCEDURE P_TWOANY;"

# --- 2. what reaches the client -----------------------------------------
both "an uncaught exception, error text and all" "SET HEADING OFF;
EXECUTE PROCEDURE P_UNCAUGHT;"
both "a bare EXCEPTION; re-raises it, with BOTH raise points" "SET HEADING OFF;
EXECUTE PROCEDURE P_RERAISE;"

# --- 3. nesting ----------------------------------------------------------
both "an inner handler catches; the outer never sees it" "SET HEADING OFF;
EXECUTE PROCEDURE P_NESTED;"
both "an inner re-raise reaches the outer handler" "SET HEADING OFF;
EXECUTE PROCEDURE P_NESTRAISE;"

# --- 4. THE POSITION COUNTS THE DDL, NOT THE BODY ------------------------
both "one-line DDL: line 1, and a column far along it" "SET HEADING OFF;
EXECUTE PROCEDURE P_ONELINE;"
both "a five-line header moves the line, not the column" "SET HEADING OFF;
EXECUTE PROCEDURE P_TALLHEAD;"

# --- 5. the identity is read AT RAISE TIME -------------------------------
# The engine looks the exception up when it is raised
# (MET_lookup_exception, StmtNodes.cpp:5947), so an ALTER EXCEPTION is
# visible to the very next raise. A server that bound the message when
# it parsed the body would keep answering the old one - and both servers
# are asked before and after here.
both "the message before ALTER" "SET HEADING OFF;
EXECUTE PROCEDURE P_UNCAUGHT;"
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" <<EOF >/dev/null 2>&1
ALTER EXCEPTION E_MINE 'changed underneath';
COMMIT;
EOF
both "...and after it, from the same procedure" "SET HEADING OFF;
EXECUTE PROCEDURE P_UNCAUGHT;"

# --- 6. a raise undoes what the body wrote -------------------------------
both "a body that wrote and then raised leaves nothing behind" "SET HEADING OFF;
EXECUTE PROCEDURE P_WROTE;
SELECT COUNT(*) FROM T;"

# --- 7. TEETH ------------------------------------------------------------
# Every check above compares two servers, so a shared refusal would look
# like agreement. These say the interpreter really ran the bodies: the
# ANSWERS -1..-7 can only come from handlers, and the raise path can
# only be reached by a body that ran.
answers=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE P_ANY;
EXECUTE PROCEDURE P_NAMED;
EXECUTE PROCEDURE P_ANYAFTER;
EXECUTE PROCEDURE P_NESTED;
EXECUTE PROCEDURE P_NESTRAISE;")
check "teeth: the handlers ran and answered" "$answers" "-1|-2|-5|11|-7|"
raised=$(grep -c 'exception E_MINE' "$LOG")
ran=$((ran + 1))
if [ "$raised" -ge 4 ]; then
    echo "OK   teeth: $raised raises reached the wire as exceptions, not refusals"
else
    echo "DIFF teeth: only $raised raises logged - are they still refusals?"; fail=1
fi

echo "ran $ran checks"
exit $fail
