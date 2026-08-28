#!/bin/bash
# A TRIGGER BODY THAT LOOPS, AND ONE THAT CALLS.
#
# `serve-real-trigdb.sh` gave a body the database: it can read one row
# with `SELECT INTO` and write others. This gate is the rest of that
# surface - the statements that read MANY rows, and the ones that hand
# the work to a procedure:
#
#   FOR SELECT ... INTO ... DO      a declared CURSOR (OPEN/FETCH/CLOSE)
#   EXECUTE PROCEDURE P(...)        EXECUTE PROCEDURE P RETURNING_VALUES
#
# THE LAW THAT DECIDES THE IMPLEMENTATION, probed against the engine
# first: A LOOP TAKES ITS ROWS WHEN IT STARTS. A `FOR SELECT` over a
# table whose own loop body INSERTS into that same table still walks
# only the rows that were there when it opened - measured: a body
# looping over a two-row table, inserting one row per iteration, runs
# TWICE and leaves four rows. The same holds for a cursor between its
# OPEN and its CLOSE. So the rows are taken once, up front; a loop that
# re-read the table would not terminate on the engine's own fixture.
#
# Everything else follows the rules the previous gate established: the
# body sees the file the statement has published, its writes go back
# with a failing statement, and what it assigns to `NEW.<col>` is what
# gets stored.
#
# THE TRIGGERS HERE ARE CREATED BY THE ENGINE, on both files, because
# this server does not COMPILE a `FOR SELECT` or a cursor into BLR (it
# refuses to store a trigger whose body it could not write back - see
# body_has_uninterpretable_blr). What is under test is RUNNING one.
#
# Boundaries (recorded): `EXECUTE STATEMENT` in such a body (it builds
# its statement at runtime, where the prepare-time walk can see no table
# name to judge) and an autonomous block (a transaction of its own
# around a published working copy, never measured).
#
#   qa/serve-real-trigloop.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4948}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-trigloop-crab.fdb"
B="$D/fc-trigloop-engine.fdb"
LOG="/tmp/fc-serve-trigloop-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/trigloop.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER, A INTEGER, K INTEGER);
CREATE TABLE SRC (X INTEGER, K INTEGER);
CREATE TABLE C (ID INTEGER, A INTEGER);
CREATE TABLE LOGT (ID INTEGER, W VARCHAR(12), N INTEGER);
CREATE TABLE CUR (ID INTEGER, A INTEGER);
CREATE TABLE PRC (ID INTEGER, A INTEGER);
CREATE TABLE SELFI (ID INTEGER, A INTEGER);
CREATE TABLE ES (ID INTEGER, A INTEGER);
COMMIT;
INSERT INTO SRC VALUES (1, 1);
INSERT INTO SRC VALUES (2, 1);
INSERT INTO SRC VALUES (3, 2);
INSERT INTO C VALUES (1, 10);
INSERT INTO C VALUES (2, 20);
INSERT INTO C VALUES (3, 30);
COMMIT;
SET TERM ^ ;
CREATE EXCEPTION EXL 'the loop said no'^
CREATE PROCEDURE ADDLOG (I INTEGER, V INTEGER) AS
BEGIN
  INSERT INTO LOGT (ID, W, N) VALUES (:I, 'proc', :V);
END^
CREATE PROCEDURE SUMC RETURNS (S INTEGER) AS
BEGIN
  SELECT SUM(A) FROM C INTO :S;
END^
/* 1. FOR SELECT: sum another table into NEW, logging each row */
CREATE TRIGGER T_BI FOR T BEFORE INSERT AS
DECLARE VARIABLE V INTEGER;
DECLARE VARIABLE S INTEGER;
BEGIN
  S = 0;
  FOR SELECT X FROM SRC ORDER BY X INTO :V DO
  BEGIN
    S = S + :V;
    INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'row', :V);
  END
  NEW.A = :S;
END^
/* 2. a loop query that reads BY THE ROW THAT FIRED IT */
CREATE TRIGGER T_BI2 FOR T BEFORE INSERT POSITION 5 AS
DECLARE VARIABLE V INTEGER;
DECLARE VARIABLE N INTEGER;
BEGIN
  N = 0;
  FOR SELECT X FROM SRC WHERE K = NEW.K ORDER BY X INTO :V DO
    N = N + 1;
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'bykey', :N);
END^
/* 3. THE STABILITY LAW: the loop body writes what the loop is reading */
CREATE TRIGGER SELFI_BI FOR SELFI BEFORE INSERT AS
DECLARE VARIABLE V INTEGER;
DECLARE VARIABLE N INTEGER;
BEGIN
  N = 0;
  FOR SELECT ID FROM C INTO :V DO
  BEGIN
    N = N + 1;
    IF (:N < 20) THEN INSERT INTO C (ID, A) VALUES (:V + 100, 0);
  END
  NEW.A = :N;
END^
/* 4. a declared CURSOR, opened and fetched by hand */
CREATE TRIGGER CUR_BI FOR CUR BEFORE INSERT AS
DECLARE VARIABLE V INTEGER;
DECLARE VARIABLE S INTEGER;
DECLARE CU CURSOR FOR (SELECT ID FROM C ORDER BY ID);
BEGIN
  S = 0;
  OPEN CU;
  FETCH CU INTO :V;
  S = S + :V;
  FETCH CU INTO :V;
  S = S + :V;
  CLOSE CU;
  NEW.A = :S;
END^
/* 5. EXECUTE PROCEDURE, both forms */
CREATE TRIGGER PRC_BI FOR PRC BEFORE INSERT AS
DECLARE VARIABLE S INTEGER;
BEGIN
  EXECUTE PROCEDURE ADDLOG(NEW.ID, NEW.A);
  EXECUTE PROCEDURE SUMC RETURNING_VALUES :S;
  NEW.A = :S;
END^
/* 6. a LEAVE out of a loop, and a raise from inside one */
CREATE TRIGGER T_AI FOR T AFTER INSERT AS
DECLARE VARIABLE V INTEGER;
BEGIN
  FOR SELECT X FROM SRC ORDER BY X INTO :V DO
  BEGIN
    IF (:V = 3) THEN LEAVE;
    IF (NEW.ID = 99) THEN EXCEPTION EXL;
    INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'after', :V);
  END
END^
SET TERM ; ^
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/trigloop.sql" >/dev/null 2>&1
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# ---- FOR SELECT --------------------------------------------------------
both "a FOR SELECT sums another table into NEW, and logs each row" \
  "INSERT INTO T (ID, A, K) VALUES (1, 0, 1); COMMIT;
   SELECT ID, A, K FROM T ORDER BY ID; SELECT ID, W, N FROM LOGT ORDER BY W, N;"
both "...the loop query reads BY THE ROW THAT FIRED IT" \
  "DELETE FROM LOGT; DELETE FROM T; COMMIT;
   INSERT INTO T (ID, A, K) VALUES (1, 0, 1);
   INSERT INTO T (ID, A, K) VALUES (2, 0, 2);
   INSERT INTO T (ID, A, K) VALUES (3, 0, 9); COMMIT;
   SELECT ID, W, N FROM LOGT WHERE W = 'bykey' ORDER BY ID;"
both "...and the log rows in the ORDER the statement wrote them" \
  "SELECT ID, W, N FROM LOGT;"
both "a LEAVE ends the loop, in an AFTER body" \
  "SELECT ID, W, N FROM LOGT WHERE W = 'after' ORDER BY ID, N;"
both "a raise from inside a loop takes the statement back" \
  "DELETE FROM LOGT; COMMIT;
   INSERT INTO T (ID, A, K) VALUES (99, 0, 1);
   SELECT COUNT(*) AS TN FROM T WHERE ID = 99; SELECT COUNT(*) AS L FROM LOGT;"

# ---- the stability law -------------------------------------------------
both "a FOR SELECT does NOT see the rows its own body inserts" \
  "INSERT INTO SELFI (ID, A) VALUES (1, 0); COMMIT;
   SELECT ID, A FROM SELFI ORDER BY ID; SELECT COUNT(*) AS CN FROM C;"
both "...and the same loop over the table as it now stands" \
  "INSERT INTO SELFI (ID, A) VALUES (2, 0); COMMIT;
   SELECT ID, A FROM SELFI ORDER BY ID; SELECT COUNT(*) AS CN FROM C;"

# ---- a declared cursor -------------------------------------------------
both "OPEN, two FETCHes and CLOSE" \
  "INSERT INTO CUR (ID, A) VALUES (1, 0); COMMIT; SELECT ID, A FROM CUR ORDER BY ID;"

# ---- EXECUTE PROCEDURE -------------------------------------------------
both "a body CALLS a procedure that writes, and one that answers" \
  "DELETE FROM LOGT; COMMIT;
   INSERT INTO PRC (ID, A) VALUES (1, 7); COMMIT;
   SELECT ID, A FROM PRC ORDER BY ID; SELECT ID, W, N FROM LOGT ORDER BY ID;"

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT ID, A, K FROM T ORDER BY ID; SELECT ID, A FROM C ORDER BY ID; SELECT ID, A FROM CUR ORDER BY ID; SELECT ID, A FROM PRC ORDER BY ID; SELECT ID, W, N FROM LOGT ORDER BY ID, W, N;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- boundaries --------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     [$r]"; fail=1 ;;
    esac
}
"$ISQL" -q -user "$U" -pas "$P" "$A" >/dev/null 2>&1 <<'SQL'
SET TERM ^ ;
CREATE TRIGGER ES_BI FOR ES BEFORE INSERT AS
DECLARE VARIABLE S VARCHAR(200);
BEGIN
  S = 'INSERT INTO LOGT (ID, W, N) VALUES (1, ''es'', 1)';
  EXECUTE STATEMENT :S;
END^
SET TERM ; ^
COMMIT;
SQL
refuses "EXECUTE STATEMENT in such a body (its statement is built at runtime)" \
  "INSERT INTO ES (ID, A) VALUES (1, 1);"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
