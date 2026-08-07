#!/bin/bash
# THE STATEMENT A BODY BUILDS AT RUNTIME - `EXECUTE STATEMENT`.
#
# It is `isc_dsql_execute_immediate` seen from the inside, so the text
# goes down the SAME plan chain a client's statement does and a query
# goes down the ordinary planner. What has to be gated is not that a
# SELECT works - it is the contract around it, because every rule in it
# would silently answer WRONG if it were guessed:
#
#   * ROW_COUNT IS NOT TOUCHED by a dynamic DML. A body that updates two
#     rows, then runs a dynamic update, then reads ROW_COUNT, still
#     answers 2 - the count of the last STATIC statement (probed);
#   * a singleton that matched NOTHING leaves the INTO slots alone, as a
#     FETCH past the end does;
#   * a singleton that matched MORE THAN ONE ROW raises 21000 rather
#     than taking the first;
#   * the INTO slots must equal the projected columns exactly, and a
#     query with NO INTO at all is the same "Output parameters mismatch";
#   * a NULL or empty text is not a no-op: it is the engine's -104
#     "Unexpected end of command - line 1, column 1".
#
# It also gates what the dynamic statement IS while it runs: this
# transaction's writes are visible to it, its own writes die with the
# body that failed, and what it raises the body may catch.
#
# THE ENABLER GATED WITH IT: a body's DML failure now carries the
# engine's own error (a duplicate key, a NOT NULL) instead of a generic
# Dynamic SQL Error - which is what makes "catch what the dynamic
# statement raised" possible at all, and is checked here for the STATIC
# form too.
#
#   qa/serve-real-execstmt.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4710}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-execstmt.fdb"
LOG="/tmp/fc-serve-execstmt-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
/* TT is the TEETH's own table, read by nothing else: the boundary check
   for WITH AUTONOMOUS TRANSACTION makes the ENGINE commit a row that
   the enclosing ROLLBACK cannot take back - correctly - and a teeth
   count over the shared table would move under it. */
CREATE TABLE TT (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10);
INSERT INTO T VALUES (2,20);
INSERT INTO T VALUES (3,30);
INSERT INTO TT VALUES (1,10);
INSERT INTO TT VALUES (2,20);
INSERT INTO TT VALUES (3,30);
COMMIT;
SET TERM ^;
/* --- the three shapes --- */
CREATE PROCEDURE E_INTO RETURNS (N INTEGER) AS
BEGIN EXECUTE STATEMENT 'SELECT V FROM T WHERE ID = 2' INTO :N; END^
CREATE PROCEDURE E_TWO RETURNS (N INTEGER) AS
DECLARE A INTEGER;
DECLARE B INTEGER;
BEGIN
  EXECUTE STATEMENT 'SELECT ID, V FROM T WHERE ID = 2' INTO :A, :B;
  N = A * 100 + B;
END^
CREATE PROCEDURE E_FOR RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN
  N = 0;
  FOR EXECUTE STATEMENT 'SELECT V FROM T ORDER BY ID' INTO :V DO
    N = N + V;
END^
CREATE PROCEDURE E_LEAVE RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN
  N = 0;
  FOR EXECUTE STATEMENT 'SELECT V FROM T ORDER BY ID' INTO :V DO
  BEGIN
    N = N + V;
    IF (N > 25) THEN LEAVE;
  END
END^
/* --- the text is BUILT: a variable, and a concatenation --- */
CREATE PROCEDURE E_VAR RETURNS (N INTEGER) AS
DECLARE S VARCHAR(200);
BEGIN
  S = 'SELECT V FROM T WHERE ID = 3';
  EXECUTE STATEMENT S INTO :N;
END^
CREATE PROCEDURE E_CONCAT RETURNS (N INTEGER) AS
DECLARE S VARCHAR(200);
DECLARE K INTEGER;
BEGIN
  K = 2;
  S = 'SELECT V FROM T WHERE ID = ' || :K;
  EXECUTE STATEMENT :S INTO :N;
END^
CREATE PROCEDURE E_INLINE RETURNS (N INTEGER) AS
DECLARE K INTEGER;
BEGIN
  K = 1;
  EXECUTE STATEMENT 'SELECT V FROM T WHERE ID = ' || :K INTO :N;
END^
/* --- ROW_COUNT: the one a converter would get wrong for free --- */
CREATE PROCEDURE E_ROWCOUNT RETURNS (N INTEGER) AS
BEGIN
  UPDATE T SET V = V + 1 WHERE ID > 1;
  EXECUTE STATEMENT 'UPDATE T SET V = V + 1 WHERE ID = 1';
  N = ROW_COUNT;
END^
CREATE PROCEDURE E_RCLOOP RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN
  FOR EXECUTE STATEMENT 'SELECT V FROM T ORDER BY ID' INTO :V DO
    N = ROW_COUNT;
END^
/* --- the INTO contract --- */
CREATE PROCEDURE E_NONE RETURNS (N INTEGER) AS
BEGIN
  N = 42;
  EXECUTE STATEMENT 'SELECT V FROM T WHERE ID = 12345' INTO :N;
END^
CREATE PROCEDURE E_MANY RETURNS (N INTEGER) AS
BEGIN EXECUTE STATEMENT 'SELECT V FROM T ORDER BY ID' INTO :N; END^
CREATE PROCEDURE E_MISMATCH RETURNS (N INTEGER) AS
BEGIN EXECUTE STATEMENT 'SELECT ID, V FROM T WHERE ID = 2' INTO :N; END^
CREATE PROCEDURE E_NOINTO RETURNS (N INTEGER) AS
BEGIN
  N = 1;
  EXECUTE STATEMENT 'SELECT V FROM T WHERE ID = 2';
END^
/* --- a text that is not a statement --- */
CREATE PROCEDURE E_NULLTEXT RETURNS (N INTEGER) AS
DECLARE S VARCHAR(100);
BEGIN
  N = 1;
  EXECUTE STATEMENT S;
END^
CREATE PROCEDURE E_EMPTY RETURNS (N INTEGER) AS
BEGIN
  N = 1;
  EXECUTE STATEMENT '';
END^
/* --- what the dynamic statement IS while it runs --- */
CREATE PROCEDURE E_SEESMINE RETURNS (N INTEGER) AS
BEGIN
  INSERT INTO T (ID, V) VALUES (40, 400);
  EXECUTE STATEMENT 'SELECT V FROM T WHERE ID = 40' INTO :N;
END^
CREATE PROCEDURE E_DDL RETURNS (N INTEGER) AS
BEGIN
  EXECUTE STATEMENT 'CREATE TABLE DYN2 (A INTEGER)';
  EXECUTE STATEMENT 'INSERT INTO DYN2 VALUES (5)';
  EXECUTE STATEMENT 'SELECT A FROM DYN2' INTO :N;
END^
CREATE PROCEDURE E_WRITETHENFAIL RETURNS (N INTEGER) AS
DECLARE Z INTEGER;
BEGIN
  EXECUTE STATEMENT 'INSERT INTO T (ID, V) VALUES (60, 600)';
  Z = 0;
  N = 1/Z;
END^
CREATE PROCEDURE E_CALL RETURNS (N INTEGER) AS
BEGIN EXECUTE STATEMENT 'EXECUTE PROCEDURE HELPER' INTO :N; END^
CREATE PROCEDURE HELPER RETURNS (R INTEGER) AS BEGIN R = 7; END^
/* --- what it raises, the body may catch --- */
CREATE PROCEDURE E_DUPCATCH RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  EXECUTE STATEMENT 'INSERT INTO T (ID, V) VALUES (1, 1)';
  WHEN ANY DO N = -1;
END^
CREATE PROCEDURE E_DUPUNCAUGHT RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  EXECUTE STATEMENT 'INSERT INTO T (ID, V) VALUES (1, 1)';
END^
/* --- the enabler, in its STATIC form --- */
CREATE PROCEDURE S_DUPCATCH RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  INSERT INTO T (ID, V) VALUES (1, 1);
  WHEN ANY DO N = -1;
END^
CREATE PROCEDURE S_DUPSTATE RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  INSERT INTO T (ID, V) VALUES (1, 1);
  WHEN SQLSTATE '23000' DO N = -2;
END^
CREATE PROCEDURE S_DUPUNCAUGHT RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  INSERT INTO T (ID, V) VALUES (1, 1);
END^
CREATE PROCEDURE S_NOTNULL RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  INSERT INTO T (ID, V) VALUES (NULL, 1);
  WHEN ANY DO N = -3;
END^
/* --- ROW_COUNT before anything has run --- */
CREATE PROCEDURE S_RCFIRST RETURNS (N INTEGER) AS
BEGIN
  IF (ROW_COUNT IS NULL) THEN N = -1; ELSE N = ROW_COUNT;
END^
/* --- the RECORDED BOUNDARIES: forms this server does not serve --- */
CREATE PROCEDURE B_PARM RETURNS (N INTEGER) AS
DECLARE K INTEGER;
BEGIN
  K = 3;
  EXECUTE STATEMENT ('SELECT V FROM T WHERE ID = ?') (K) INTO :N;
END^
CREATE PROCEDURE B_AUTONOMOUS RETURNS (N INTEGER) AS
BEGIN
  EXECUTE STATEMENT 'INSERT INTO T (ID, V) VALUES (77, 777)'
    WITH AUTONOMOUS TRANSACTION;
  N = 1;
END^
CREATE PROCEDURE B_BADPREPARE RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  EXECUTE STATEMENT 'SELECT NOSUCH FROM T';
  WHEN ANY DO N = -1;
END^
/* a string assigned to a NUMERIC output: the engine CONVERTS it, and a
   server that answered the raw text would render 0 into the wire's
   integer slot - so this must refuse, never answer */
CREATE PROCEDURE B_TEXTINNUM RETURNS (N INTEGER) AS
BEGIN N = '5'; END^
/* --- the TEETH's own procedures, over TT --- */
CREATE PROCEDURE TE_TWO RETURNS (N INTEGER) AS
DECLARE A INTEGER;
DECLARE B INTEGER;
BEGIN
  EXECUTE STATEMENT 'SELECT ID, V FROM TT WHERE ID = 2' INTO :A, :B;
  N = A * 100 + B;
END^
CREATE PROCEDURE TE_FOR RETURNS (N INTEGER) AS
DECLARE V INTEGER;
BEGIN
  N = 0;
  FOR EXECUTE STATEMENT 'SELECT V FROM TT ORDER BY ID' INTO :V DO
    N = N + V;
END^
CREATE PROCEDURE TE_CONCAT RETURNS (N INTEGER) AS
DECLARE S VARCHAR(200);
DECLARE K INTEGER;
BEGIN
  K = 2;
  S = 'SELECT V FROM TT WHERE ID = ' || :K;
  EXECUTE STATEMENT :S INTO :N;
END^
CREATE PROCEDURE TE_ROWCOUNT RETURNS (N INTEGER) AS
BEGIN
  UPDATE TT SET V = V + 1 WHERE ID > 1;
  EXECUTE STATEMENT 'UPDATE TT SET V = V + 1 WHERE ID = 1';
  N = ROW_COUNT;
END^
CREATE PROCEDURE TE_DDL RETURNS (N INTEGER) AS
BEGIN
  EXECUTE STATEMENT 'CREATE TABLE DYN3 (A INTEGER)';
  EXECUTE STATEMENT 'INSERT INTO DYN3 VALUES (5)';
  EXECUTE STATEMENT 'SELECT A FROM DYN3' INTO :N;
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

call() { # <label> <procedure>
    both "$1" "SET HEADING OFF;
EXECUTE PROCEDURE $2;
ROLLBACK;"
}

# --- 1. the three shapes -------------------------------------------------
call "EXECUTE STATEMENT ... INTO" E_INTO
call "two projected columns into two slots" E_TWO
call "FOR EXECUTE STATEMENT, once per row" E_FOR
call "...and LEAVE ends it" E_LEAVE

# --- 2. the text is BUILT ------------------------------------------------
call "the text comes out of a variable" E_VAR
call "...built by concatenating a value into it" E_CONCAT
call "...or concatenated in the statement itself" E_INLINE

# --- 3. ROW_COUNT --------------------------------------------------------
# The count belongs to the last STATIC statement: a dynamic UPDATE that
# changed a row does NOT move it.
call "a dynamic DML does not touch ROW_COUNT" E_ROWCOUNT
call "...nor does a FOR EXECUTE STATEMENT loop" E_RCLOOP
call "ROW_COUNT is 0 before any statement, not NULL" S_RCFIRST

# --- 4. the INTO contract ------------------------------------------------
call "a singleton that matched nothing leaves the slot alone" E_NONE
call "more than one row is 21000, not the first row" E_MANY
call "two columns into one slot is a mismatch" E_MISMATCH
call "...and so is a query with no INTO at all" E_NOINTO

# --- 5. a text that is not a statement -----------------------------------
call "a NULL text is -104, not a no-op" E_NULLTEXT
call "...and so is an empty one" E_EMPTY

# --- 6. what the dynamic statement is while it runs ----------------------
call "it sees this transaction's uncommitted rows" E_SEESMINE
call "DDL through it, then the table it made" E_DDL
call "its write dies with the body that failed" E_WRITETHENFAIL
both "...and the row is not there afterwards" "SET HEADING OFF;
EXECUTE PROCEDURE E_WRITETHENFAIL;
SELECT COUNT(*) FROM T WHERE ID = 60;"
call "EXECUTE PROCEDURE through a dynamic string" E_CALL

# --- 7. what it raises, the body may catch -------------------------------
call "WHEN ANY catches what the dynamic statement raised" E_DUPCATCH
call "uncaught, the client gets the engine's own error" E_DUPUNCAUGHT

# --- 8. the enabler: a body's own DML failure has an identity ------------
call "a static duplicate key is catchable" S_DUPCATCH
call "...by its SQLSTATE too" S_DUPSTATE
call "...and uncaught it names the constraint, table and key" S_DUPUNCAUGHT
call "a NOT NULL violation is catchable" S_NOTNULL

# --- 9. RECORDED BOUNDARIES ----------------------------------------------
# These are ASSERTIONS, not comments: when one of them lands, this gate
# must FAIL rather than quietly agree, so the boundary cannot move
# unnoticed. Each names what the engine answers and what fire-crab does.
boundary() { # <label> <procedure> <expected fc answer prefix>
    local eng fc
    eng=$(run "$DB" "SET HEADING OFF;
EXECUTE PROCEDURE $2;
ROLLBACK;")
    fc=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE $2;
ROLLBACK;")
    ran=$((ran + 1))
    if [ "$eng" != "$fc" ] && [ "${fc#*$3}" != "$fc" ]; then
        echo "OK   boundary: $1 (engine [$eng], fc refuses)"
    else
        echo "DIFF boundary MOVED: $1"
        echo "     engine: $eng"
        echo "     fc:     $fc"
        fail=1
    fi
}
# parameters after the text, and WITH AUTONOMOUS TRANSACTION, are the two
# clauses this slice does not serve; a prepare failure inside the dynamic
# statement is a REFUSAL here because this server cannot yet tell "your
# column does not exist" (the engine's -206) from "this shape is outside
# my surface" - so it must not borrow the typed vector.
boundary "EXECUTE STATEMENT (...) (params)" B_PARM "Dynamic SQL Error"
boundary "WITH AUTONOMOUS TRANSACTION" B_AUTONOMOUS "Dynamic SQL Error"
boundary "a dynamic statement that fails to PREPARE" B_BADPREPARE "Dynamic SQL Error"
# and the guard the text surface needed: the engine CONVERTS '5' into an
# INTEGER output; the wire's integer slot renders a text value as 0, so a
# server without this check answers 5 as 0 - a wrong answer, not a
# missing feature. It refuses instead, both through the source
# interpreter and through the BLR executor that runs first.
boundary "a string assigned to a numeric output" B_TEXTINNUM "Dynamic SQL Error"

# --- 10. TEETH -----------------------------------------------------------
# Both servers are compared, so a SHARED refusal reads as agreement.
# These answers can only come from bodies that really built, prepared and
# ran their statements, and the log must show no refusal for them.
answers=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
EXECUTE PROCEDURE TE_TWO;
EXECUTE PROCEDURE TE_FOR;
EXECUTE PROCEDURE TE_CONCAT;
EXECUTE PROCEDURE TE_ROWCOUNT;
ROLLBACK;
EXECUTE PROCEDURE TE_DDL;
ROLLBACK;")
ran=$((ran + 1))
if [ "$answers" = "220|60|20|2|5|" ]; then
    echo "OK   teeth: the statements were built, prepared and run"
else
    echo "DIFF teeth: [$answers]"; fail=1
fi
# the log must show the dynamic text this server actually executed - a
# body that answered from somewhere else would leave none
seen=$(grep -c "psql execute statement" "$LOG")
ran=$((ran + 1))
if [ "$seen" -ge 20 ]; then
    echo "OK   teeth: $seen dynamic statements went down the execute path"
else
    echo "DIFF teeth: only $seen dynamic statements were executed"; fail=1
fi

echo "ran $ran checks"
exit $fail
