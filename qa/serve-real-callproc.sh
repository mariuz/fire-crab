#!/bin/bash
# A BODY CALLING A BODY, AND WHAT ROW_COUNT MEANS AFTER DML.
#
# `EXECUTE PROCEDURE` inside PSQL was refused, so every body that
# factors work into another procedure was refused with it. It is a
# NESTED FRAME: the callee gets its own variables, its own cursors and
# its own ROW_COUNT, and its writes are this transaction's writes.
#
# The part worth gating hardest is what crosses the boundary:
#
#   * RETURNING_VALUES fills the CALLER's slots from the callee's
#     output parameters, in order;
#   * an error the callee raises is the CALLER's to catch - a WHEN ANY
#     around the call catches a division by zero inside the callee;
#   * uncaught, it names BOTH frames, innermost first, in the
#     `At procedure ... line: L, col: C` items;
#   * a callee that writes and a caller that fails leave NOTHING
#     behind: one statement, one undo.
#
# ROW_COUNT rides along because it is the same frame slot: a FETCH sets
# it (qa/serve-real-cursors.sh), and so does every DML - including 0 for
# one that matched nothing, rather than leaving the previous count.
#
#   qa/serve-real-callproc.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4708}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-callproc.fdb"
LOG="/tmp/fc-serve-callproc-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE M (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO M VALUES (1,10);
INSERT INTO M VALUES (2,20);
INSERT INTO M VALUES (3,30);
COMMIT;
SET TERM ^;
/* the callees */
CREATE PROCEDURE INNER1 RETURNS (R INTEGER) AS BEGIN R = 7; END^
CREATE PROCEDURE INNER2 (A INTEGER, B INTEGER) RETURNS (R INTEGER, Q INTEGER) AS
BEGIN R = A + B; Q = A * B; END^
CREATE PROCEDURE INNER_RAISE RETURNS (R INTEGER) AS
DECLARE Z INTEGER;
BEGIN Z = 0; R = 1/Z; END^
CREATE PROCEDURE INNER_WRITE RETURNS (R INTEGER) AS
BEGIN INSERT INTO M (ID, V) VALUES (50, 500); R = ROW_COUNT; END^
/* the callers */
CREATE PROCEDURE N_CALL RETURNS (N INTEGER) AS
BEGIN EXECUTE PROCEDURE INNER1 RETURNING_VALUES :N; END^
CREATE PROCEDURE N_ARGS RETURNS (N INTEGER) AS
DECLARE X INTEGER;
DECLARE Y INTEGER;
BEGIN EXECUTE PROCEDURE INNER2(3, 4) RETURNING_VALUES :X, :Y; N = X * 100 + Y; END^
CREATE PROCEDURE N_EXPRARGS RETURNS (N INTEGER) AS
DECLARE X INTEGER;
DECLARE Y INTEGER;
DECLARE K INTEGER;
BEGIN K = 5; EXECUTE PROCEDURE INNER2(K + 1, K * 2) RETURNING_VALUES :X, :Y; N = X * 100 + Y; END^
CREATE PROCEDURE N_LOOP RETURNS (N INTEGER) AS
DECLARE I INTEGER;
DECLARE V INTEGER;
BEGIN
  N = 0; I = 0;
  WHILE (I < 3) DO
  BEGIN
    I = I + 1;
    EXECUTE PROCEDURE INNER1 RETURNING_VALUES :V;
    N = N + V;
  END
END^
/* the callee's error, caught and uncaught */
CREATE PROCEDURE N_CATCH RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN N = 0; EXECUTE PROCEDURE INNER_RAISE RETURNING_VALUES :V; WHEN ANY DO N = -1; END^
CREATE PROCEDURE N_CATCHCODE RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN
  N = 0;
  EXECUTE PROCEDURE INNER_RAISE RETURNING_VALUES :V;
  WHEN SQLSTATE '22012' DO N = -2;
END^
CREATE PROCEDURE N_UNCAUGHT RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN N = 0; EXECUTE PROCEDURE INNER_RAISE RETURNING_VALUES :V; N = V; END^
/* a callee that writes, and a caller that raises afterwards */
CREATE PROCEDURE N_WRITETHENFAIL RETURNS (N INTEGER) AS
DECLARE V INTEGER;
DECLARE Z INTEGER;
BEGIN
  EXECUTE PROCEDURE INNER_WRITE RETURNING_VALUES :V;
  Z = 0;
  N = 1/Z;
END^
/* ROW_COUNT after each kind of DML */
CREATE PROCEDURE R_UPD RETURNS (N INTEGER) AS
BEGIN UPDATE M SET V = V + 1 WHERE ID > 1; N = ROW_COUNT; END^
CREATE PROCEDURE R_INS RETURNS (N INTEGER) AS
BEGIN INSERT INTO M (ID, V) VALUES (9, 99); N = ROW_COUNT; END^
CREATE PROCEDURE R_DELNONE RETURNS (N INTEGER) AS
BEGIN DELETE FROM M WHERE ID = 12345; N = ROW_COUNT; END^
CREATE PROCEDURE R_TWICE RETURNS (N INTEGER) AS
DECLARE A INTEGER;
BEGIN
  UPDATE M SET V = V + 1 WHERE ID > 1;
  A = ROW_COUNT;
  DELETE FROM M WHERE ID = 12345;
  N = A * 10 + ROW_COUNT;
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

# --- 1. the call ---------------------------------------------------------
both "EXECUTE PROCEDURE ... RETURNING_VALUES" "SET HEADING OFF;
EXECUTE PROCEDURE N_CALL;"
both "arguments in, two values out" "SET HEADING OFF;
EXECUTE PROCEDURE N_ARGS;"
both "the arguments may be expressions over the caller's variables" "SET HEADING OFF;
EXECUTE PROCEDURE N_EXPRARGS;"
both "a call inside a loop, three times" "SET HEADING OFF;
EXECUTE PROCEDURE N_LOOP;"

# --- 2. the callee's error is the caller's to catch ----------------------
both "WHEN ANY around the call catches what the callee raised" "SET HEADING OFF;
EXECUTE PROCEDURE N_CATCH;"
both "...and so does the callee's own SQLSTATE" "SET HEADING OFF;
EXECUTE PROCEDURE N_CATCHCODE;"
both "uncaught, it names BOTH frames, innermost first" "SET HEADING OFF;
EXECUTE PROCEDURE N_UNCAUGHT;"

# --- 3. one statement, one undo ------------------------------------------
# The callee INSERTs and the caller then divides by zero. Nothing may
# survive: the write belongs to the statement that failed.
both "a callee's write dies with the caller's failure" "SET HEADING OFF;
EXECUTE PROCEDURE N_WRITETHENFAIL;"
both "...and the row is not there afterwards" "SET HEADING OFF;
SELECT COUNT(*) FROM M WHERE ID = 50;"

# --- 4. ROW_COUNT after DML ----------------------------------------------
both "ROW_COUNT after an UPDATE that touched two rows" "SET HEADING OFF;
EXECUTE PROCEDURE R_UPD;
ROLLBACK;"
both "ROW_COUNT after an INSERT" "SET HEADING OFF;
EXECUTE PROCEDURE R_INS;
ROLLBACK;"
both "ROW_COUNT is 0 for a DELETE that matched nothing" "SET HEADING OFF;
EXECUTE PROCEDURE R_DELNONE;"
both "it is the LAST statement's count, not a running total" "SET HEADING OFF;
EXECUTE PROCEDURE R_TWICE;
ROLLBACK;"

# --- 5. TEETH ------------------------------------------------------------
# Both servers are compared, so a shared refusal reads as agreement.
# These answers can only come from bodies that really called and really
# counted, and the log must show no refusal.
answers=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE N_ARGS;
EXECUTE PROCEDURE N_LOOP;
EXECUTE PROCEDURE N_CATCH;
EXECUTE PROCEDURE R_DELNONE;")
ran=$((ran + 1))
if [ "$answers" = "712|21|-1|0|" ]; then
    echo "OK   teeth: the calls ran, and the counts came from the statements"
else
    echo "DIFF teeth: [$answers]"; fail=1
fi
refused=$(grep -c "does not interpret\|outside this server's PSQL surface" "$LOG")
ran=$((ran + 1))
if [ "$refused" -eq 0 ]; then
    echo "OK   teeth: no body was refused"
else
    echo "DIFF teeth: $refused bodies were refused"; fail=1
fi

echo "ran $ran checks"
exit $fail
