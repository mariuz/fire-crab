#!/bin/bash
# A SELECTABLE PROCEDURE'S BODY IS PULLED, NOT RUN AND THEN SLICED.
#
# The engine stops a selectable body as soon as the consumer stops
# asking: `FIRST 1` runs it once, `FIRST 2` twice, `ROWS 2 TO 3` three
# times. fire-crab ran every body to completion and sliced the rows
# afterwards, which is invisible for a pure body and TWO WRONG ANSWERS
# for one that is not:
#
#   * a body with a SIDE EFFECT does it too many times, and
#   * a body that RAISES past the limit raises where the engine never
#     reaches the raise at all - `SELECT FIRST 2 K FROM PRAISE` answers
#     two rows and no error there, and raised here.
#
# HOW THE ITERATIONS ARE COUNTED. Rows alone cannot see this: FIRST 2
# over a run-out body and over a stopped one return the same two rows.
# So the procedure LOGS ONE ROW PER ITERATION and the log count IS the
# number of times the body ran - the only way the difference is
# observable, and the reason this gate has a fixture of its own.
#
# WHICH CONSUMERS STOP IT, all measured against the live engine:
#
#   bare                 5     FIRST 1              1
#   FIRST 2              2     FIRST 99             5   (limit > rows)
#   FIRST 1 SKIP 1       2     ROWS 2               2
#   ROWS 2 TO 3          3     SKIP 2               5   (no bound)
#   derived + FIRST 1    1     WHERE                5   (a filter does
#   ORDER BY             5      not stop the body)
#   COUNT(*)             5     DISTINCT             5
#   FIRST 2 + ORDER BY   5     EXECUTE PROCEDURE    1
#
# The blocking ones matter as much as the stopping ones: a sort, an
# aggregate or a DISTINCT consumes the WHOLE body on the engine, so a
# cap applied there would be a wrong answer rather than a saving. Both
# halves are asserted here.
#
#   qa/serve-real-proclazy.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4318}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-proclazy-work.fdb"   # fire-crab serves this one
REF="$D/fc-proclazy-ref.fdb"     # the engine serves this one

mkdir -p "$D"; rm -f "$WORK" "$REF"
fail=0

make_db() {
    rm -f "$1"
    # CREATED EMBEDDED, THEN `chmod 666` - the house idiom, and the
    # reason is OWNERSHIP: a database created over TCP belongs to the
    # ENGINE's user, so this gate (running as another) cannot chmod it
    # and fire-crab cannot write it - the first cut did exactly that and
    # died at "Operation not permitted". Created here the file is ours,
    # and 666 lets the engine open it over TCP. Only the QUERIES of the
    # differential must hold the transport fixed; the fixture need not.
    "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 <<EOF || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE LOG (N INTEGER);
COMMIT;
CREATE EXCEPTION E_MINE 'boom from the body';
COMMIT;
SET TERM ^;
/* ONE LOG ROW PER ITERATION: the log count is how many times the body
   ran, which is the only way the pull is observable */
CREATE PROCEDURE PLOG (M INTEGER) RETURNS (K INTEGER) AS
DECLARE VARIABLE I INTEGER;
BEGIN
  I = 1;
  WHILE (I <= M) DO BEGIN
    INSERT INTO LOG (N) VALUES (:I);
    K = I; SUSPEND; I = I + 1;
  END
END^
/* two rows, then a RAISE: a consumer that stops early never reaches it */
CREATE PROCEDURE PRAISE RETURNS (K INTEGER) AS
BEGIN
  K = 1; SUSPEND;
  K = 2; SUSPEND;
  EXCEPTION E_MINE;
END^
/* WRITES, suspends, then raises. One cell then pins both halves of the
   engine's answer at once: the ROWS arrive (they were produced before
   the failure) and the WRITES do not (the body is undone), because
   `iters` folds the log count into what it compares. */
CREATE PROCEDURE PRW RETURNS (K INTEGER) AS
BEGIN
  INSERT INTO LOG (N) VALUES (1); K = 1; SUSPEND;
  INSERT INTO LOG (N) VALUES (2); K = 2; SUSPEND;
  EXCEPTION E_MINE;
END^
SET TERM ;^
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$WORK" || { echo "FAIL scratch WORK"; exit 1; }
make_db "$REF"  || { echo "FAIL scratch REF"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-proclazy.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
i=0; while [ $i -lt 20 ]; do
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "SOMETHING is listening" is not "OUR server is listening": if the port
# was taken, fcwire exited at bind and every check below would run
# against the other server and report success while measuring nothing.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# Run <stmt>, then read how many times the body ran. The DELETE and the
# COMMIT bracket it so each cell counts its own statement only.
iters() { # <connstring> <stmt>
    printf 'DELETE FROM LOG; COMMIT;\nSET HEADING OFF;\n%s;\nCOMMIT;\nSELECT COUNT(*) FROM LOG;\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' ' |
        sed 's/^ //; s/ $//'
}
# the answer AND the iteration count, compared as one string: a cell that
# got the right rows the wrong way round still fails
cell() { # <label> <stmt>
    local e f
    e=$(iters "127.0.0.1/$REAL:$REF" "$2")
    f=$(iters "127.0.0.1/$PORT:$WORK" "$2")
    if [ -z "$e" ] || [ -z "$f" ]; then
        echo "DIFF $1 read nothing (engine=[$e] fc=[$f])"; fail=1; return
    fi
    if [ "$e" = "$f" ]; then
        # the value is printed on SUCCESS too, so a run that agrees for
        # the wrong reason is visible in the log
        echo "OK   $1 [$e]"
    else
        echo "DIFF $1"; echo "     engine: [$e]"; echo "     fc:     [$f]"; fail=1
    fi
}

# THE POSITIVE CONTROL. Every cell below compares two servers, so a
# probe that never ran the body at all would make both agree on zero and
# the whole gate would pass while measuring nothing.
base=$(iters "127.0.0.1/$REAL:$REF" "SELECT K FROM PLOG(5)")
case "$base" in
    *" 5"*) echo "OK   control: the ENGINE runs an unbounded body 5 times [$base]" ;;
    *) echo "DIFF control: the engine did not run the body - [$base]"; fail=1 ;;
esac

echo "-- the consumers that STOP the body --"
cell "FIRST 1 runs the body once"        "SELECT FIRST 1 K FROM PLOG(5)"
cell "FIRST 2 runs it twice"             "SELECT FIRST 2 K FROM PLOG(5)"
cell "FIRST 1 SKIP 1 counts skip+take"   "SELECT FIRST 1 SKIP 1 K FROM PLOG(5)"
cell "ROWS 2"                            "SELECT K FROM PLOG(5) ROWS 2"
cell "ROWS 2 TO 3 counts the end"        "SELECT K FROM PLOG(5) ROWS 2 TO 3"
cell "a limit through a derived table"   "SELECT FIRST 1 K FROM (SELECT K FROM PLOG(5)) DT"

echo "-- ...and the consumers that must NOT stop it --"
cell "an unbounded body"                 "SELECT K FROM PLOG(5)"
cell "a limit bigger than the body"      "SELECT FIRST 99 K FROM PLOG(5)"
cell "a bare SKIP has no bound"          "SELECT SKIP 2 K FROM PLOG(5)"
cell "a WHERE filters, it does not stop" "SELECT K FROM PLOG(5) WHERE K > 3"
cell "a SORT is blocking"                "SELECT K FROM PLOG(5) ORDER BY K DESC"
cell "a limit UNDER a sort is blocking"  "SELECT FIRST 2 K FROM PLOG(5) ORDER BY K"
cell "an aggregate is blocking"          "SELECT COUNT(*) FROM PLOG(5)"
cell "DISTINCT is blocking"              "SELECT DISTINCT K FROM PLOG(5)"
cell "EXECUTE PROCEDURE is a limit of 1" "EXECUTE PROCEDURE PLOG(5)"

# THE WRONG ANSWER THE PULL FIXES, and the reason this ranks above a
# missed optimisation: a body that RAISES past the limit. The engine
# never reaches the raise, so the statement ANSWERS; fire-crab ran the
# body out and raised.
echo "-- a body that raises PAST the limit --"
cell "FIRST 2 stops before the raise"    "SELECT FIRST 2 K FROM PRAISE"
cell "FIRST 1 stops before the raise"    "SELECT FIRST 1 K FROM PRAISE"
cell "ROWS 2 stops before the raise"     "SELECT K FROM PRAISE ROWS 2"

# ...AND WHEN THE RAISE IS REACHED, THE ROWS COME FIRST.
#
# The engine delivers what the body already produced and raises AFTER
# it; fire-crab used to raise with no rows at all. The carrier is a
# trailing error on the rows themselves, so the fetch writes the rows
# and then the engine's status vector in the same reply - which is what
# a per-row arithmetic exception mid-cursor has always done.
#
# The writing body pins the other half in the same cell: its rows arrive
# and its WRITES DO NOT (the body is undone on a raise, on both servers),
# because `iters` compares the log count along with the rows.
echo "-- ...and when the raise IS reached, the rows come first --"
cell "a bare raising body: rows, then the raise" "SELECT K FROM PRAISE"
cell "a limit PAST the raise still raises"       "SELECT FIRST 3 K FROM PRAISE"
cell "a WRITING raising body: rows yes, writes no" "SELECT K FROM PRW"

# RECORDED, NOT FIXED - measured here, left as it is:
#
#   A LIMIT WITH A FILTER counts SURVIVING rows, which the body's cap
#   cannot express: `SELECT FIRST 1 K FROM PLOG(5) WHERE K > 3` is FOUR
#   iterations on the engine (it pulls until one row passes the filter)
#   and five here. The rows are identical; only the side-effect count
#   differs. Implementing it needs the filter evaluated inside the
#   body's pull rather than above it.
#
# It is recorded the honest way round: NOT as an OK cell, and not hidden
# either - that number is what a future slice must move.

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$WORK" "$REF"
[ $fail = 0 ] && echo "PASS proclazy" || echo "FAIL proclazy"
exit $fail
