#!/bin/bash
# A TRANSACTION INSIDE A TRANSACTION - `IN AUTONOMOUS TRANSACTION`.
#
# The block runs under a transaction of its OWN: it commits when the
# block finishes, dies if the block raises, and neither outcome is the
# outer transaction's to decide. That is the whole point of it - an
# audit row that survives the failure of the work it was recording.
#
# THIS GATE HOLDS EACH SERVER'S DATABASE APART, which no other
# serve-real gate needs to do. Every one of them runs both servers over
# the SAME file, because a rollback puts the file back; an autonomous
# commit is exactly the thing a rollback does NOT put back, so the
# engine's run would seed fire-crab's with its own rows and every later
# check would meet a duplicate key. Two identical databases, built by
# the same script, one per side - and the engine is reached over TCP so
# the transport is the same on both (an embedded attachment is a second
# difference, and it talks).
#
# What is gated:
#
#   * the block COMMITS on its own, and what it wrote SURVIVES the
#     failure of the body around it;
#   * an error INSIDE the block rolls the block back and then escapes,
#     so the caller may catch it and nothing it wrote remains;
#   * several statements in one block commit together;
#   * `EXECUTE STATEMENT ... WITH AUTONOMOUS TRANSACTION` is the same
#     requirement in the engine's other syntax, and behaves the same;
#   * DDL through it, and a plain assignment inside it;
#   * a BODY THAT HAS ALREADY WRITTEN around it, and a BLOCK INSIDE A
#     BLOCK - both refused until an undo window became a transaction of
#     its own, and both measured here by the DIVISION they turn on: the
#     failed body's own writes go back, the block's stay.
#
#   qa/serve-real-autonomous.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4711}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-auto-engine.fdb"
DBF="$D/fc-auto-crab.fdb"
LOG="/tmp/fc-serve-autonomous-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

build() { # <path>
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
CREATE TABLE LOG (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10);
INSERT INTO T VALUES (2,20);
COMMIT;
SET TERM ^;
/* --- it commits on its own --- */
CREATE PROCEDURE A_PLAIN RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (1, 100);
  N = 1;
END^
/* --- ...and survives the failure of the body around it --- */
CREATE PROCEDURE A_SURVIVES RETURNS (N INTEGER) AS
DECLARE Z INTEGER;
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (2, 200);
  Z = 0;
  N = 1/Z;
END^
/* --- an error inside the block: it rolls back, the error escapes --- */
CREATE PROCEDURE A_RAISES RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  IN AUTONOMOUS TRANSACTION DO
  BEGIN
    INSERT INTO LOG (ID, V) VALUES (3, 300);
    INSERT INTO LOG (ID, V) VALUES (3, 301);   /* duplicate key */
  END
END^
CREATE PROCEDURE A_CAUGHT RETURNS (N INTEGER) AS
BEGIN
  N = 0;
  IN AUTONOMOUS TRANSACTION DO
  BEGIN
    INSERT INTO LOG (ID, V) VALUES (4, 400);
    INSERT INTO LOG (ID, V) VALUES (4, 401);
  END
  WHEN ANY DO N = -1;
END^
/* --- several statements, one commit --- */
CREATE PROCEDURE A_MANY RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
  BEGIN
    INSERT INTO LOG (ID, V) VALUES (6, 600);
    INSERT INTO LOG (ID, V) VALUES (7, 700);
  END
  N = 1;
END^
/* --- the other syntax for the same thing --- */
CREATE PROCEDURE A_EXECSTMT RETURNS (N INTEGER) AS
DECLARE Z INTEGER;
BEGIN
  EXECUTE STATEMENT 'INSERT INTO LOG (ID, V) VALUES (11, 1100)'
    WITH AUTONOMOUS TRANSACTION;
  Z = 0;
  N = 1/Z;
END^
/* --- what else may be inside it --- */
CREATE PROCEDURE A_ASSIGN RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    N = 5;
  SUSPEND;
END^
CREATE PROCEDURE A_DDL RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    EXECUTE STATEMENT 'CREATE TABLE AUTODDL (A INTEGER)';
  N = 1;
END^
/* --- a read after the block, of something the block did NOT write --- */
CREATE PROCEDURE A_READAFTER RETURNS (N INTEGER) AS
DECLARE C INTEGER;
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (13, 1300);
  EXECUTE STATEMENT 'SELECT COUNT(*) FROM LOG WHERE ID = 99' INTO :C;
  N = C + 1;
END^
/* --- A BODY THAT HAS ALREADY WRITTEN, and a BLOCK INSIDE A BLOCK: both
   were refused while an undo window's only undo was an image restore.
   A window is a TRANSACTION now, so both are answered - and what has to
   be measured is the DIVISION: the body's own writes go, the block's
   stay. --- */
CREATE PROCEDURE B_WROTEFIRST RETURNS (N INTEGER) AS
BEGIN
  UPDATE T SET V = V WHERE ID > 0;
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (8, 800);
  N = ROW_COUNT;
END^
/* the body writes, the block commits, THEN the body fails: the body's
   UPDATE must be undone and the block's INSERT must not. An image
   restore plus a page carve-out gets this wrong in the one direction
   that is silent - it carries the body's own rows forward with the
   autonomous ones. */
CREATE PROCEDURE B_WROTETHENFAILS RETURNS (N INTEGER) AS
BEGIN
  UPDATE T SET V = 999 WHERE ID = 1;
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (20, 2000);
  N = 1 / 0;
END^
/* a block inside a block */
CREATE PROCEDURE B_NESTED RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
  BEGIN
    INSERT INTO LOG (ID, V) VALUES (9, 900);
    IN AUTONOMOUS TRANSACTION DO
      INSERT INTO LOG (ID, V) VALUES (10, 1000);
  END
  N = 1;
END^
/* ...and the inner one commits while the OUTER one dies */
CREATE PROCEDURE B_NESTEDOUTERFAILS RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
  BEGIN
    INSERT INTO LOG (ID, V) VALUES (21, 2100);
    IN AUTONOMOUS TRANSACTION DO
      INSERT INTO LOG (ID, V) VALUES (22, 2200);
    N = 1 / 0;
  END
  N = 1;
END^
/* the outer transaction reading what the block committed */
CREATE PROCEDURE B_OUTERSEES RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (12, 1200);
  EXECUTE STATEMENT 'SELECT COUNT(*) FROM LOG WHERE ID = 12' INTO :N;
END^
SET TERM ;^
COMMIT;
EOF
}
rm -f "$DBE" "$DBF"
build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

run() { # <conn> <sql>
    printf '%s\n' "$2" | timeout 30 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}
eng() { run "127.0.0.1/$REAL:$DBE" "$1"; }
crab() { run "127.0.0.1/$PORT:$DBF" "$1"; }

both() { # <label> <sql>
    local e c
    e=$(eng "$2"); c=$(crab "$2")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi
}
call() { # <label> <procedure>
    both "$1" "SET HEADING OFF;
EXECUTE PROCEDURE $2;
ROLLBACK;"
}

# --- 1. it commits on its own --------------------------------------------
call "the block commits" A_PLAIN
both "...and the row is there after the rollback" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 1;"

# --- 2. and survives the body's failure ----------------------------------
# The body divides by zero AFTER the block. The engine keeps what the
# block committed; a server whose undo is "put the image back" takes it
# away unless the block's pages are carried forward.
call "the body fails after the block" A_SURVIVES
both "...and the block's row is STILL there" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 2;"

# --- 3. an error inside the block ----------------------------------------
call "an error inside the block escapes it" A_RAISES
both "...and nothing the block wrote remains" "SET HEADING OFF;
SELECT COUNT(*) FROM LOG WHERE ID = 3;"
call "...and the caller may catch it" A_CAUGHT
both "...with nothing left behind either" "SET HEADING OFF;
SELECT COUNT(*) FROM LOG WHERE ID = 4;"

# --- 4. several statements, one commit -----------------------------------
call "two statements in one block" A_MANY
both "...both committed" "SET HEADING OFF;
SELECT COUNT(*) FROM LOG WHERE ID IN (6, 7);"

# --- 5. the other syntax -------------------------------------------------
call "EXECUTE STATEMENT ... WITH AUTONOMOUS TRANSACTION" A_EXECSTMT
both "...survives the same failure" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 11;"

# --- 6. what else may be inside it ---------------------------------------
call "a plain assignment inside the block" A_ASSIGN
call "DDL inside the block" A_DDL
both "...and the table it made is there" "SET HEADING OFF;
SELECT COUNT(*) FROM AUTODDL;"
call "a read after the block" A_READAFTER

# --- 7. RECORDED BOUNDARIES ----------------------------------------------
# ASSERTIONS, not comments: when one of these moves, this gate must FAIL
# rather than quietly agree.
boundary() { # <label> <procedure> <what fc must answer, substring>
    local e c
    e=$(eng "SET HEADING OFF;
EXECUTE PROCEDURE $2;
ROLLBACK;")
    c=$(crab "SET HEADING OFF;
EXECUTE PROCEDURE $2;
ROLLBACK;")
    ran=$((ran + 1))
    if [ "$e" != "$c" ] && [ "${c#*$3}" != "$c" ]; then
        echo "OK   boundary: $1 (engine [$e], fc [$c])"
    else
        echo "DIFF boundary MOVED: $1"
        echo "     engine: $e"
        echo "     fc:     $c"
        fail=1
    fi
}
# --- 7a. WHAT A SAVEPOINT-AS-A-TRANSACTION LIFTED ------------------------
# Both of these were RECORDED BOUNDARIES here, refused because the body's
# own writes could only be undone by putting an image back and the
# carve-out that keeps the autonomous pages would have carried them
# forward with it. An undo window has a transaction id of its own now, so
# the body's writes are killed by two bits and the block's are untouched.
call "the body wrote before the block" B_WROTEFIRST
both "...and the block's row is there" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 8;"
# THE DIVISION ITSELF, which is the whole of this: the body fails AFTER
# both writes, so its UPDATE goes back to 10 and the block's INSERT stays.
call "the body wrote, the block committed, then the body failed" B_WROTETHENFAILS
both "...the block's row survives" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 20;"
both "...and the BODY's own UPDATE is undone" "SET HEADING OFF;
SELECT V FROM T WHERE ID = 1;"
call "a block inside a block" B_NESTED
both "...both rows are there" "SET HEADING OFF;
SELECT COUNT(*) FROM LOG WHERE ID IN (9, 10);"
call "the inner block commits, the outer one dies" B_NESTEDOUTERFAILS
both "...the inner block's row survives" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 22;"
both "...and the outer block's does not" "SET HEADING OFF;
SELECT COUNT(*) FROM LOG WHERE ID = 21;"
# THE OUTER TRANSACTION READING WHAT THE BLOCK COMMITTED. The engine
# answers 0, and this was a RECORDED BOUNDARY until the read-consistency
# slice converted it. isql's default TPB is read committed no record
# version, which the engine runs as READ COMMITTED READ CONSISTENCY: a
# statement's view is fixed at its start, so the row the block commits
# mid-statement is not seen. Nor is it seen by a LATER statement of the
# same transaction - the engine never shows a transaction the rows its
# own autonomous block committed. fire-crab models both now (a per-
# statement view, plus holding its own committed autonomous ids out of
# it), so the two agree at 0 where they used to split 0/1.
both "the outer transaction does not see its own block's commit" "SET HEADING OFF;
EXECUTE PROCEDURE B_OUTERSEES;
ROLLBACK;"

# --- 8. TEETH ------------------------------------------------------------
# Both servers are compared, so a shared refusal reads as agreement. The
# log must show the transactions this server opened and committed, and
# the carve-out that keeps them.
opened=$(grep -c "autonomous transaction .* opened" "$LOG")
committed=$(grep -c "autonomous transaction .* Committed" "$LOG")
dead=$(grep -c "autonomous transaction .* Dead" "$LOG")
carved=$(grep -c "autonomous carve-out" "$LOG")
ran=$((ran + 1))
if [ "$opened" -ge 8 ] && [ "$committed" -ge 6 ] && [ "$dead" -ge 2 ]; then
    echo "OK   teeth: $opened opened, $committed committed, $dead rolled back"
else
    echo "DIFF teeth: opened=$opened committed=$committed dead=$dead"; fail=1
fi
ran=$((ran + 1))
if [ "$carved" -ge 6 ]; then
    echo "OK   teeth: $carved commits carved out of the enclosing undo"
else
    echo "DIFF teeth: only $carved carve-outs"; fail=1
fi
# and the row that proves the carve-out did its job cannot come from
# anywhere else: the body FAILED, and every other row it would have
# written is gone
ran=$((ran + 1))
kept=$(crab "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 2;")
if [ "$kept" = "200|" ]; then
    echo "OK   teeth: the committed row outlived the statement that failed"
else
    echo "DIFF teeth: [$kept]"; fail=1
fi

echo "ran $ran checks"
exit $fail
