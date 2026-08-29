#!/bin/bash
# A TRIGGER BODY THAT READS AND WRITES THE DATABASE, fired where the
# engine fires it.
#
# `serve-real-trigfire.sh` runs the bodies that need only the ROW. This
# gate is the other half, and it is the one that makes the classic
# triggers work: an AUDIT trigger (write another table), a LOOKUP
# trigger (read another table to compute a column), and any body that
# asks the database a question.
#
# A trigger fires INSIDE a statement that is holding its working copy of
# the file, and a body's own statement goes down the ORDINARY path -
# taking a copy and installing it. Two writers cloning the same base
# both install a whole image and the second silently drops the first's
# rows, so this server PUBLISHES its copy around the body and takes a
# fresh one after. Publishing is not a concession: it is what puts the
# body's read on exactly the file the engine shows it. Every law below
# was probed against the live engine first.
#
#   1. A BEFORE body reads the table WITHOUT the row being written and
#      WITH every earlier row of the same statement. Under an
#      `INSERT ... SELECT` of three rows, the per-row `SELECT COUNT(*)`
#      answers 0, 1, 2 - so a body cannot be run after the statement
#      (that answers 3, 3, 3) and cannot be run before it either.
#   2. An AFTER body reads the table WITH the row: `AFTER INSERT` counts
#      itself in, and sums the value it just stored.
#   3. A BEFORE UPDATE body reads the table AS IT STANDS - the sum
#      BEFORE this row's update - and a BEFORE DELETE body still counts
#      the row it is about to remove.
#   4. A STATEMENT THAT FAILS TAKES THE BODY'S WRITES WITH IT, however
#      far the body got: a trigger that logged a row, whose own INSERT
#      then violates a CHECK, leaves the log EMPTY.
#   5. A body's write fires the triggers of the table it writes, and
#      those fire on: T's trigger writes U, U's trigger writes the log.
#
# Boundaries (recorded, each with the reason it is not just missing):
# a body that WRITES THE TABLE IT FIRES FOR (the engine recurses to
# `Statement::MAX_CLONES` = 1000 and answers 54001; each level here is a
# whole executor frame, so this refuses rather than answering by
# crashing), a cursor / FOR SELECT / EXECUTE STATEMENT / autonomous
# block in such a body, and a body that DRAWS A GENERATOR beside one
# that needs the database (the draw belongs to the caller, which has
# handed its working copy back).
#
#   qa/serve-real-trigdb.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4933}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-trigdb-crab.fdb"
B="$D/fc-trigdb-engine.fdb"
LOG="/tmp/fc-serve-trigdb-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/trigdb.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER, A INTEGER, K INTEGER, CHECK (A < 1000));
CREATE TABLE U (ID INTEGER, A INTEGER);
CREATE TABLE LOGT (ID INTEGER, W VARCHAR(10), N INTEGER);
CREATE TABLE SRC (X INTEGER);
CREATE TABLE RATE (K INTEGER, MULT INTEGER);
CREATE TABLE P (ID INTEGER, A INTEGER);
CREATE TABLE Q (ID INTEGER, A INTEGER);
CREATE TABLE QD (ID INTEGER, A INTEGER);
CREATE TABLE R (ID INTEGER, A INTEGER);
CREATE TABLE E (ID INTEGER, A INTEGER);
CREATE TABLE N1 (ID INTEGER, A INTEGER);
CREATE TABLE N2 (ID INTEGER, A INTEGER);
CREATE TABLE NN1 (ID INTEGER NOT NULL, A INTEGER);
CREATE TABLE NN2 (ID INTEGER, A INTEGER CHECK (A < 10));
CREATE TABLE MR (ID INTEGER, A INTEGER, CHECK (A < 100));
COMMIT;
INSERT INTO SRC VALUES (1);
INSERT INTO SRC VALUES (2);
INSERT INTO SRC VALUES (3);
INSERT INTO RATE VALUES (1, 10);
INSERT INTO RATE VALUES (2, 100);
INSERT INTO P VALUES (1, 10);
INSERT INTO P VALUES (2, 20);
INSERT INTO P VALUES (3, 99);
INSERT INTO Q VALUES (1, 10);
INSERT INTO Q VALUES (2, 20);
INSERT INTO QD VALUES (1, 10);
INSERT INTO QD VALUES (2, 20);
INSERT INTO QD VALUES (3, 30);
INSERT INTO QD VALUES (4, 40);
INSERT INTO MR VALUES (1, 10);
INSERT INTO MR VALUES (2, 20);
INSERT INTO MR VALUES (3, 95);
COMMIT;
SET TERM ^ ;
CREATE EXCEPTION EXT 'the body said no'^
/* 1. THE AUDIT TRIGGER, and the count law: a BEFORE body reads its own
      table without this row and with every earlier row of this stmt */
CREATE TRIGGER T_BI FOR T BEFORE INSERT AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM T INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'bi', :C);
END^
/* 2. an AFTER body counts itself in */
CREATE TRIGGER T_AI FOR T AFTER INSERT AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM T INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'ai', :C);
END^
/* 3. THE LOOKUP TRIGGER: another table decides a column */
CREATE TRIGGER T_BI2 FOR T BEFORE INSERT POSITION 5 AS
DECLARE VARIABLE M INTEGER;
BEGIN
  SELECT MULT FROM RATE WHERE K = NEW.K INTO :M;
  IF (:M IS NOT NULL) THEN NEW.A = NEW.A * :M;
END^
/* 4. UPDATE and DELETE, reading the table around the row */
CREATE TRIGGER P_BU FOR P BEFORE UPDATE AS
DECLARE VARIABLE S INTEGER;
BEGIN
  SELECT SUM(A) FROM P INTO :S;
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'bu', :S);
END^
CREATE TRIGGER P_AU FOR P AFTER UPDATE AS
DECLARE VARIABLE S INTEGER;
BEGIN
  SELECT SUM(A) FROM P INTO :S;
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'au', :S);
END^
CREATE TRIGGER QD_BD FOR QD BEFORE DELETE AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM QD INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (OLD.ID, 'bd', :C);
END^
CREATE TRIGGER QD_AD FOR QD AFTER DELETE AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM QD INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (OLD.ID, 'ad', :C);
END^
CREATE TRIGGER Q_BD FOR Q BEFORE DELETE AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM Q INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (OLD.ID, 'bd', :C);
END^
CREATE TRIGGER Q_AD FOR Q AFTER DELETE AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM Q INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (OLD.ID, 'ad', :C);
END^
/* 5. THE CHAIN: R's body writes U, and U's body writes the log */
CREATE TRIGGER R_BI FOR R BEFORE INSERT AS
BEGIN
  INSERT INTO U (ID, A) VALUES (NEW.ID * 10, NEW.A);
END^
CREATE TRIGGER U_AI FOR U AFTER INSERT AS
BEGIN
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'chain', NEW.A);
END^
/* 8. a MULTI-ROW update whose LATER row fails: the body logged the
      earlier ones, and all of it goes back together */
CREATE TRIGGER MR_BU FOR MR BEFORE UPDATE AS
BEGIN
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'mr', NEW.A);
END^
/* 7. bodies whose OWN statement fails a constraint */
CREATE TRIGGER N1_BI FOR N1 BEFORE INSERT AS
BEGIN
  INSERT INTO NN1 (ID, A) VALUES (NULL, NEW.A);
END^
CREATE TRIGGER N2_BI FOR N2 BEFORE INSERT AS
BEGIN
  INSERT INTO NN2 (ID, A) VALUES (NEW.ID, 99);
END^
/* 6. a body that writes and THEN raises */
CREATE TRIGGER E_BI FOR E BEFORE INSERT AS
BEGIN
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'e', 1);
  IF (NEW.A = 7) THEN EXCEPTION EXT;
END^
SET TERM ; ^
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/trigdb.sql" >/dev/null 2>&1
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

# ---- the audit trigger, and what a BEFORE body sees --------------------
both "a BEFORE body writes another table, and reads its own without this row" \
  "INSERT INTO T (ID, A) VALUES (1, 5); COMMIT;
   SELECT ID, A, K FROM T ORDER BY ID; SELECT ID, W, N FROM LOGT ORDER BY ID, W;"
both "PER ROW: an INSERT ... SELECT of three rows counts 1, 2, 3 as it goes" \
  "DELETE FROM LOGT; DELETE FROM T; COMMIT;
   INSERT INTO T (ID, A) SELECT X, X FROM SRC; COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID, W; SELECT COUNT(*) AS TN FROM T;"
both "the LOOKUP trigger: another table decides the stored value" \
  "DELETE FROM LOGT; DELETE FROM T; COMMIT;
   INSERT INTO T (ID, A, K) VALUES (1, 5, 1);
   INSERT INTO T (ID, A, K) VALUES (2, 5, 2);
   INSERT INTO T (ID, A, K) VALUES (3, 5, 9); COMMIT;
   SELECT ID, A, K FROM T ORDER BY ID;"
both "...and the log the same statements wrote beside it" \
  "SELECT ID, W, N FROM LOGT ORDER BY ID, W;"

# ---- a failing statement takes the body's writes with it ---------------
both "the CHECK the trigger's own row violates leaves the log EMPTY" \
  "DELETE FROM LOGT; DELETE FROM T; COMMIT;
   INSERT INTO T (ID, A) VALUES (9, 5000);
   SELECT COUNT(*) AS L FROM LOGT; SELECT COUNT(*) AS TN FROM T;"
both "...and so does a ROLLBACK after a statement that worked" \
  "DELETE FROM LOGT; DELETE FROM T; COMMIT;
   INSERT INTO T (ID, A) VALUES (1, 1); ROLLBACK;
   SELECT COUNT(*) AS L FROM LOGT; SELECT COUNT(*) AS TN FROM T;"
both "a body that WRITES and then RAISES: the write goes back with the row" \
  "DELETE FROM LOGT; COMMIT;
   INSERT INTO E (ID, A) VALUES (1, 7);
   SELECT COUNT(*) AS L FROM LOGT; SELECT COUNT(*) AS EN FROM E;"
both "...and the same body on the branch that does not raise" \
  "INSERT INTO E (ID, A) VALUES (2, 1); COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID; SELECT ID, A FROM E ORDER BY ID;"

# ---- UPDATE: what the two bodies see around the row --------------------
both "a BEFORE UPDATE body reads the sum BEFORE, an AFTER one the sum AFTER" \
  "DELETE FROM LOGT; COMMIT;
   UPDATE P SET A = A + 1 WHERE ID = 1; COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID, W; SELECT ID, A FROM P ORDER BY ID;"
both "PER ROW: an UPDATE over three rows walks the sum up" \
  "DELETE FROM LOGT; COMMIT;
   UPDATE P SET A = A + 1; COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID, W; SELECT ID, A FROM P ORDER BY ID;"

# ---- DELETE: the row is still there for BEFORE, gone for AFTER ---------
both "a BEFORE DELETE body counts the row it is about to remove" \
  "DELETE FROM LOGT; COMMIT;
   DELETE FROM Q WHERE ID = 1; COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID, W; SELECT ID, A FROM Q ORDER BY ID;"
# QD's rows were written ONCE, at build, so both files delete them in
# the same order.
#
# WHAT PROVES THE INTERLEAVING is the COUNT each body read - 4,3 / 3,2 /
# 2,1 / 1,0 is only possible if each row's triggers ran around its own
# delete, and a batched implementation answers the same number to every
# row. Two checks used to compare the LOG TABLE's physical order as
# well, and that was never sound: the log is emptied and refilled all
# through this gate, so where its rows land is free-slot reuse, which
# the two files need not agree on. (The first fix made the DELETED rows
# stable and missed that the LOG was the unstable table - the check
# failed again, in a later sweep, for the same reason in a different
# place.)
both "PER ROW: a multi-row DELETE walks the count down as it goes" \
  "DELETE FROM LOGT; COMMIT;
   DELETE FROM QD; COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID, W; SELECT COUNT(*) AS QN FROM QD;"

# ---- a MULTI-ROW statement that fails PART WAY -------------------------
# the body logged the rows it got to; the CHECK the third row violates
# takes those log rows back with the updates
both "a multi-row UPDATE whose LAST row fails leaves NO log rows" \
  "DELETE FROM LOGT; COMMIT;
   UPDATE MR SET A = A + 10;
   SELECT COUNT(*) AS L FROM LOGT; SELECT ID, A FROM MR ORDER BY ID;"
both "...and the same statement over the rows that DO pass" \
  "DELETE FROM LOGT; COMMIT;
   UPDATE MR SET A = A + 1 WHERE ID < 3; COMMIT;
   SELECT ID, W, N FROM LOGT; SELECT ID, A FROM MR ORDER BY ID;"

# ---- the chain: a body's write fires the triggers of what it writes ----
both "R's body writes U, and U's own body writes the log" \
  "DELETE FROM LOGT; DELETE FROM U; COMMIT;
   INSERT INTO R (ID, A) VALUES (1, 7); COMMIT;
   SELECT ID, A FROM R ORDER BY ID; SELECT ID, A FROM U ORDER BY ID;
   SELECT ID, W, N FROM LOGT ORDER BY ID;"
both "...once per row of a multi-row statement" \
  "DELETE FROM LOGT; DELETE FROM U; DELETE FROM R; COMMIT;
   INSERT INTO R (ID, A) SELECT X, X * 2 FROM SRC; COMMIT;
   SELECT ID, A FROM U ORDER BY ID; SELECT ID, W, N FROM LOGT ORDER BY ID;"

# ---- the vector a body's OWN statement raises --------------------------
# the body's write goes down the ordinary path, so it meets the ordinary
# constraints - and the engine reports THAT failure, with the trigger it
# happened in on the stack
both "a NOT NULL the body's own INSERT violates" \
  "INSERT INTO N1 (ID, A) VALUES (1, 1); SELECT COUNT(*) AS NN FROM N1;"
both "a body write that violates the log table's CHECK" \
  "INSERT INTO N2 (ID, A) VALUES (1, 1); SELECT COUNT(*) AS NN FROM N2;"

# ---- RETURNING beside a firing body ------------------------------------
both "RETURNING answers the row the body decided" \
  "DELETE FROM LOGT; DELETE FROM T; COMMIT;
   INSERT INTO T (ID, A, K) VALUES (7, 5, 1) RETURNING ID, A; COMMIT;
   SELECT ID, W, N FROM LOGT ORDER BY ID, W;"

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT ID, A, K FROM T ORDER BY ID; SELECT ID, A FROM P ORDER BY ID; SELECT ID, A FROM U ORDER BY ID; SELECT ID, W, N FROM LOGT ORDER BY ID, W;"
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
# a body that writes ITS OWN table recurses: the engine runs to
# MAX_CLONES = 1000 and answers 54001, and each level here is an
# executor frame, so this refuses rather than answering by crashing
"$ISQL" -q -user "$U" -pas "$P" "$A" >/dev/null 2>&1 <<'SQL'
SET TERM ^ ;
CREATE TRIGGER T_SELF FOR U BEFORE INSERT POSITION 9 AS
BEGIN
  IF (NEW.ID < 3) THEN INSERT INTO U (ID, A) VALUES (NEW.ID + 1, 0);
END^
CREATE TRIGGER T_CUR FOR R BEFORE INSERT POSITION 9 AS
DECLARE VARIABLE V INTEGER;
BEGIN
  FOR SELECT X FROM SRC INTO :V DO
    INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'for', :V);
END^
CREATE SEQUENCE SQ^
CREATE TRIGGER Q_GEN FOR Q BEFORE INSERT POSITION 1 AS
BEGIN
  NEW.A = NEXT VALUE FOR SQ;
END^
CREATE TRIGGER Q_DB FOR Q BEFORE INSERT POSITION 2 AS
DECLARE VARIABLE C INTEGER;
BEGIN
  SELECT COUNT(*) FROM LOGT INTO :C;
  INSERT INTO LOGT (ID, W, N) VALUES (NEW.ID, 'qdb', :C);
END^
SET TERM ; ^
COMMIT;
SQL
refuses "a body that writes the table it fires FOR (the engine recurses; this refuses)" \
  "INSERT INTO U (ID, A) VALUES (1, 1);"
refuses "a FOR SELECT inside such a body" \
  "INSERT INTO R (ID, A) VALUES (9, 9);"
refuses "a body that DRAWS beside one that needs the database" \
  "INSERT INTO Q (ID, A) VALUES (9, 9);"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
