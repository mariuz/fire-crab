#!/bin/bash
# EXPLICIT CURSORS, AND THE LOOP THEY ARE FOR.
#
# `FOR SELECT ... DO` has worked for a while; the DECLARED cursor -
# `DECLARE C CURSOR FOR (...)`, `OPEN`, `FETCH ... INTO`, `CLOSE` - was
# refused whole, and with it every body that drives one. It does not
# come alone: the canonical loop needs `ROW_COUNT` to know the fetch
# found nothing and `LEAVE` to get out, so those are here too (with
# `EXIT`, which is the same kind of jump one level up).
#
# What is worth pinning, because it is the part a reimplementation gets
# wrong:
#
#   * a FETCH PAST THE END LEAVES THE VARIABLES ALONE. It does not null
#     them - probed: a variable holding 1 still holds 1 after a fetch
#     that found nothing - and ROW_COUNT is how the body tells the two
#     apart;
#   * LEAVE ends the INNERMOST loop only;
#   * EXIT ends the BODY, from any depth, and a selectable procedure
#     keeps the rows it has already SUSPENDed.
#
# The cursor's query goes through the ORDINARY planner, so a cursor sees
# what a client SELECT sees; the joins and expressions below are there
# to hold that rather than a private mini-planner.
#
#   qa/serve-real-cursors.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4706}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-cursors.fdb"
LOG="/tmp/fc-serve-cursors-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(10), G INTEGER);
CREATE TABLE U (ID INTEGER NOT NULL PRIMARY KEY, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,'a',10);
INSERT INTO T VALUES (2,'b',20);
INSERT INTO T VALUES (3,'c',10);
INSERT INTO U VALUES (1,100);
INSERT INTO U VALUES (2,200);
INSERT INTO U VALUES (3,300);
COMMIT;
SET TERM ^;
/* the three statements, once through */
CREATE PROCEDURE C_ONE RETURNS (N INTEGER) AS
DECLARE C CURSOR FOR (SELECT ID FROM T ORDER BY ID);
BEGIN OPEN C; FETCH C INTO :N; CLOSE C; END^
/* the canonical loop: FETCH, ROW_COUNT, LEAVE */
CREATE PROCEDURE C_LOOP RETURNS (N INTEGER) AS
DECLARE V INTEGER;
DECLARE C CURSOR FOR (SELECT ID FROM T ORDER BY ID);
BEGIN
  N = 0;
  OPEN C;
  WHILE (1=1) DO
  BEGIN
    FETCH C INTO :V;
    IF (ROW_COUNT = 0) THEN LEAVE;
    N = N + V;
  END
  CLOSE C;
END^
/* Past the end: the slot KEEPS its value, and ROW_COUNT says what
   happened. Two procedures rather than one returning both, because a
   procedure with TWO output columns exposes a divergence that has
   nothing to do with cursors: fire-crab announces every output
   parameter as BIGINT, so isql pads the columns differently from the
   engine's INTEGER. The VALUES agree; the widths do not. Named here so
   the next person does not read it as a cursor bug. */
CREATE PROCEDURE C_PASTEND RETURNS (N INTEGER) AS
DECLARE C CURSOR FOR (SELECT ID FROM T WHERE ID = 1);
BEGIN N = -1; OPEN C; FETCH C INTO :N; FETCH C INTO :N; CLOSE C; END^
CREATE PROCEDURE C_PASTCOUNT RETURNS (R INTEGER) AS
DECLARE V INTEGER;
DECLARE C CURSOR FOR (SELECT ID FROM T WHERE ID = 1);
BEGIN V = -1; OPEN C; FETCH C INTO :V; FETCH C INTO :V; R = ROW_COUNT; CLOSE C; END^
/* two columns into two variables, answered one at a time */
CREATE PROCEDURE C_TWO RETURNS (A INTEGER) AS
DECLARE B INTEGER;
DECLARE C CURSOR FOR (SELECT ID, G FROM T ORDER BY ID DESC);
BEGIN OPEN C; FETCH C INTO :A, :B; CLOSE C; A = A * 1000 + B; END^
/* The ORDINARY planner is behind it: a join, a filter, an expression.
   NB THE ALIAS IS REQUIRED - probed against FB6: inside a DECLARE
   CURSOR, an expression in the select list without a name is "Invalid
   command", though the identical SELECT runs standalone. */
CREATE PROCEDURE C_JOIN RETURNS (N INTEGER) AS
DECLARE V INTEGER;
DECLARE C CURSOR FOR
  (SELECT A.ID * B.W AS P FROM T A JOIN U B ON B.ID = A.ID WHERE A.G = 10 ORDER BY A.ID);
BEGIN
  N = 0;
  OPEN C;
  WHILE (1=1) DO
  BEGIN
    FETCH C INTO :V;
    IF (ROW_COUNT = 0) THEN LEAVE;
    N = N + V;
  END
  CLOSE C;
END^
/* LEAVE ends the INNERMOST loop only */
CREATE PROCEDURE C_NESTED RETURNS (N INTEGER) AS
DECLARE I INTEGER;
DECLARE J INTEGER;
BEGIN
  N = 0; I = 0;
  WHILE (I < 3) DO
  BEGIN
    I = I + 1;
    J = 0;
    WHILE (J < 10) DO
    BEGIN
      J = J + 1;
      IF (J = 2) THEN LEAVE;
      N = N + 1;
    END
    N = N + 100;
  END
END^
/* EXIT ends the BODY from inside a loop */
CREATE PROCEDURE C_EXITLOOP RETURNS (N INTEGER) AS
DECLARE I INTEGER;
BEGIN
  N = 0; I = 0;
  WHILE (I < 10) DO
  BEGIN
    I = I + 1;
    N = N + 1;
    IF (I = 2) THEN EXIT;
  END
  N = 999;
END^
/* a selectable procedure driven by a cursor, and one that EXITs midway
   keeping the rows it already suspended */
CREATE PROCEDURE C_SEL RETURNS (N INTEGER) AS
DECLARE C CURSOR FOR (SELECT ID FROM T ORDER BY ID);
BEGIN
  OPEN C;
  WHILE (1=1) DO
  BEGIN
    FETCH C INTO :N;
    IF (ROW_COUNT = 0) THEN LEAVE;
    SUSPEND;
  END
  CLOSE C;
END^
CREATE PROCEDURE C_SELEXIT RETURNS (N INTEGER) AS
DECLARE C CURSOR FOR (SELECT ID FROM T ORDER BY ID);
BEGIN
  OPEN C;
  WHILE (1=1) DO
  BEGIN
    FETCH C INTO :N;
    IF (ROW_COUNT = 0) THEN LEAVE;
    IF (N = 3) THEN EXIT;
    SUSPEND;
  END
  CLOSE C;
END^
/* LEAVE inside a FOR SELECT, which is a loop too */
CREATE PROCEDURE C_FORLEAVE RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN
  N = 0;
  FOR SELECT ID FROM T ORDER BY ID INTO :V DO
  BEGIN
    IF (V = 3) THEN LEAVE;
    N = N + V;
  END
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
    printf '%s\n' "$2" | timeout 30 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
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

# --- 1. the statements ---------------------------------------------------
both "OPEN, FETCH, CLOSE" "SET HEADING OFF;
EXECUTE PROCEDURE C_ONE;"
both "two columns into two variables" "SET HEADING OFF;
EXECUTE PROCEDURE C_TWO;"

# --- 2. the loop they are for --------------------------------------------
both "the canonical loop: FETCH, ROW_COUNT, LEAVE" "SET HEADING OFF;
EXECUTE PROCEDURE C_LOOP;"
both "a fetch past the end KEEPS the slot's value" "SET HEADING OFF;
EXECUTE PROCEDURE C_PASTEND;"
both "...and ROW_COUNT is how the body knows" "SET HEADING OFF;
EXECUTE PROCEDURE C_PASTCOUNT;"

# --- 3. the ordinary planner is behind the cursor ------------------------
both "a cursor over a join, a filter and an expression" "SET HEADING OFF;
EXECUTE PROCEDURE C_JOIN;"

# --- 4. what LEAVE and EXIT end ------------------------------------------
both "LEAVE ends the INNERMOST loop only" "SET HEADING OFF;
EXECUTE PROCEDURE C_NESTED;"
both "EXIT ends the BODY, from inside a loop" "SET HEADING OFF;
EXECUTE PROCEDURE C_EXITLOOP;"
both "LEAVE works in a FOR SELECT too" "SET HEADING OFF;
EXECUTE PROCEDURE C_FORLEAVE;"

# --- 5. a selectable procedure driven by a cursor ------------------------
both "a cursor loop with SUSPEND is a result set" "SET HEADING OFF;
SELECT * FROM C_SEL;"
both "...and EXIT keeps the rows already suspended" "SET HEADING OFF;
SELECT * FROM C_SELEXIT;"
both "EXECUTE PROCEDURE on the selectable one answers its first row" "SET HEADING OFF;
EXECUTE PROCEDURE C_SEL;"

# --- 6. TEETH ------------------------------------------------------------
# Both servers are compared, so a shared refusal would read as
# agreement: these say the bodies RAN. Every answer below needs the
# cursor to have moved, and the log must show no refusal at all.
answers=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE C_LOOP;
EXECUTE PROCEDURE C_JOIN;
EXECUTE PROCEDURE C_NESTED;
EXECUTE PROCEDURE C_FORLEAVE;")
ran=$((ran + 1))
if [ "$answers" = "6|1000|303|3|" ]; then
    echo "OK   teeth: the loops ran and answered"
else
    echo "DIFF teeth: the loops did not answer [$answers]"; fail=1
fi
refused=$(grep -c "does not interpret\|outside this server's PSQL surface" "$LOG")
ran=$((ran + 1))
if [ "$refused" -eq 0 ]; then
    echo "OK   teeth: no body was refused - the cursors really ran"
else
    echo "DIFF teeth: $refused bodies were refused"; fail=1
fi

echo "ran $ran checks"
exit $fail
