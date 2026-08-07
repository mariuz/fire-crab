#!/bin/bash
# A SAVEPOINT IS A TRANSACTION - what the engine's undo records do, done
# with the one mechanism this server has for making writes stop counting.
#
# The engine keeps an undo record per changed record inside a savepoint
# and replays them backwards (`tra.cpp`'s verb machinery,
# `VIO_verb_cleanup`), which needs a writer that can take a record
# version off a page. This server has no such writer - it had ONE undo,
# "put the image back", and every savepoint therefore cost a copy of the
# database and could not be trusted while anybody else was committing.
#
# What it does have is the thing that makes a transaction's rows stop
# counting: two bits in the TIP. So each undo window - a SAVEPOINT, a
# PSQL body, a row-by-row statement - reserves a transaction id of its
# own at its first write, and undoing the window is `tra_dead` on that
# id. A reader then walks past those versions to the ones behind them,
# which are exactly the pre-savepoint values.
#
# WHAT THIS GATE MEASURES, and why each one would be silently wrong if
# the mechanism were guessed:
#
#   * the work before a mark survives, the work after it does not -
#     including an UPDATE (the version behind the dead one is the old
#     value) and a DELETE (whose undo is a stub that stops counting);
#   * A STATEMENT AFTER THE UNDO READS THE RESTORED VALUE, not the dead
#     version's - `SET V = V + 1` after a `ROLLBACK TO` is the check,
#     because a writer that reads the chain HEAD instead of the visible
#     version computes from work that was rolled back;
#   * a key inserted after the mark can be inserted AGAIN after the undo
#     (the uniqueness check reads records, and a dead one is not a
#     record) - while a duplicate of a row inserted BEFORE the mark is
#     still refused, which is the other half of the same rule and the
#     one a nested id gets wrong for free: the writer must count the
#     transaction's WHOLE set of ids, not just the innermost;
#   * nested marks, RELEASE, a second undo to the same mark, and a full
#     ROLLBACK over the top of them;
#   * DDL inside a mark still falls back to the IMAGE, because a catalog
#     row here is settled as it is written and no transaction state can
#     take it back.
#
# Every read that judges is taken in a FRESH isql invocation, so what
# answers is the file's transaction states and not the server's memory,
# and the last section hands the file to `gfix` and to the engine.
#
# THE TWO SERVERS GET THEIR OWN DATABASE FILE, for the reason
# serve-real-autonomous.sh gives: these scripts COMMIT, and a shared file
# would seed the second server with the first's rows.
#
#   qa/serve-real-savepointtx.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4714}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-savepointtx-engine.fdb"
DBF="$D/fc-savepointtx-crab.fdb"
LOG="/tmp/fc-serve-savepointtx-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

build() { # <path>
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
COMMIT;
SET TERM ^;
/* a body writes inside the mark - its window is nested INSIDE the
   mark's, so its id folds into the mark's when it returns and dies with
   the mark when the mark is rolled back */
CREATE PROCEDURE P_INS (K INTEGER) AS
BEGIN
  INSERT INTO T (ID, V) VALUES (:K, 1);
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

# --- 1. the work before a mark, and the work after it ---------------------
both "an INSERT after the mark is undone, the one before it is not" \
"INSERT INTO T VALUES (10, 100);
SAVEPOINT S;
INSERT INTO T VALUES (11, 110);
ROLLBACK TO S;
COMMIT;"
both "...and a FRESH reader sees exactly that" "SET HEADING OFF;
SELECT ID FROM T WHERE ID IN (10, 11) ORDER BY ID;"

# --- 2. an UPDATE undone is the version behind the dead one --------------
both "an UPDATE after the mark is undone" \
"UPDATE T SET V = 99 WHERE ID = 1;
SAVEPOINT S;
UPDATE T SET V = 77 WHERE ID = 1;
ROLLBACK TO S;
COMMIT;"
both "...leaving the value the statement before the mark wrote" "SET HEADING OFF;
SELECT V FROM T WHERE ID = 1;"

# --- 3. THE STATEMENT AFTER THE UNDO READS THE RESTORED VALUE ------------
# `SET V = V + 1` has to compute from the version the reader SEES. A
# writer that takes the chain head instead computes from the update that
# was just rolled back, and answers 21 where the engine answers 6.
both "an UPDATE after the undo computes from the restored value" \
"UPDATE T SET V = 5 WHERE ID = 2;
SAVEPOINT S;
UPDATE T SET V = 20 WHERE ID = 2;
ROLLBACK TO S;
UPDATE T SET V = V + 1 WHERE ID = 2;
COMMIT;"
both "...so it is 6, not 21" "SET HEADING OFF;
SELECT V FROM T WHERE ID = 2;"

# --- 4. a DELETE after the mark ------------------------------------------
both "a DELETE after the mark is undone" \
"SAVEPOINT S;
DELETE FROM T WHERE ID = 2;
ROLLBACK TO S;
COMMIT;"
both "...and the row is still there" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID = 2;"

# --- 5. the key an undone insert left in the index -----------------------
# The entry is still in the tree - a window undone by transaction state
# removes nothing - so re-inserting the same primary key asks whether the
# uniqueness check reads ENTRIES or RECORDS. Records, and only the ones
# this reader counts.
both "a key inserted after the mark can be inserted again" \
"SAVEPOINT S;
INSERT INTO T VALUES (30, 1);
ROLLBACK TO S;
INSERT INTO T VALUES (30, 2);
COMMIT;"
both "...once, with the second value" "SET HEADING OFF;
SELECT COUNT(*) || '/' || MAX(V) FROM T WHERE ID = 30;"

# --- 6. ...AND THE OTHER HALF OF THAT RULE ------------------------------
# A duplicate of a row inserted BEFORE the mark must still be refused.
# The rows before the mark carry the TRANSACTION's id and the ones after
# it a nested one, so a writer that counts only the id it is writing
# under cannot see them - and allows a duplicate primary key.
both "a duplicate of a row written BEFORE the mark is still refused" \
"INSERT INTO T VALUES (40, 1);
SAVEPOINT S;
INSERT INTO T VALUES (40, 2);
COMMIT;"
# ...and isql -b bails on that error, so the transaction never reaches
# its COMMIT and NEITHER row is there - the same on both sides, which is
# the point: the refusal is the answer, and it costs the whole script.
both "...and neither row survives the bail" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID = 40;"

# --- 7. nested marks, RELEASE, and a full ROLLBACK over them -------------
both "ROLLBACK TO the outer mark discards the inner one's work too" \
"INSERT INTO T VALUES (50, 1);
SAVEPOINT A;
INSERT INTO T VALUES (51, 1);
SAVEPOINT B;
INSERT INTO T VALUES (52, 1);
ROLLBACK TO A;
COMMIT;"
both "...only the row before the outer mark survives" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID IN (50, 51, 52);"

both "RELEASE keeps the work" \
"INSERT INTO T VALUES (60, 1);
SAVEPOINT A;
INSERT INTO T VALUES (61, 1);
RELEASE SAVEPOINT A;
COMMIT;"
both "...both rows are committed" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID IN (60, 61);"

both "a full ROLLBACK beats every mark" \
"INSERT INTO T VALUES (70, 1);
SAVEPOINT A;
INSERT INTO T VALUES (71, 1);
ROLLBACK;"
both "...neither row is there" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID IN (70, 71);"

both "the mark survives its own undo, and the second undo goes to the same place" \
"SAVEPOINT S;
INSERT INTO T VALUES (80, 1);
ROLLBACK TO S;
INSERT INTO T VALUES (81, 1);
ROLLBACK TO S;
COMMIT;"
both "...so neither row is there" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID IN (80, 81);"

# --- 7b. A BODY INSIDE A MARK -------------------------------------------
# A window inside a window: the body reserves its own id, and when it
# returns that id folds into the MARK's - so the mark's undo kills it and
# the mark's RELEASE keeps it. Both directions, because a mechanism that
# forgets a folded id passes the first and fails the second.
both "a body's writes inside a mark are undone with the mark" \
"SAVEPOINT S;
EXECUTE PROCEDURE P_INS(100);
ROLLBACK TO S;
COMMIT;"
both "...the row the body wrote is gone" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID = 100;"
both "a body's writes inside a RELEASED mark are committed" \
"SAVEPOINT S;
EXECUTE PROCEDURE P_INS(101);
RELEASE SAVEPOINT S;
COMMIT;"
both "...the row the body wrote is there" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID = 101;"

# --- 8. DDL INSIDE A MARK: the image is still the fallback ---------------
# A catalog row is settled as it is written here - this server's DDL is
# not transactional - so no transaction state can take it back and the
# mark's image is what undoes it. Both servers run the same script with
# AUTODDL OFF, so the setting decides which law is measured rather than
# which side wins.
both "a rolled-back mark that contains DDL" \
"SET AUTODDL OFF;
INSERT INTO T VALUES (90, 1);
SAVEPOINT S;
CREATE TABLE SPDDL (X INTEGER);
INSERT INTO T VALUES (91, 1);
ROLLBACK TO S;
COMMIT;"
both "...the table it made is gone" "SET HEADING OFF;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'SPDDL';"
both "...the row before the mark is committed, the one after it is not" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID IN (90, 91);"

# --- 9. COVERAGE: the undo was TRANSACTION STATE, not an image ----------
# A gate that only compares answers cannot tell which mechanism produced
# them - and the old one produced most of these correctly at the cost of
# a database copy per mark. This reads the server's own trace.
ran=$((ran + 1))
killed=$(grep -c 'undo window: transactions' "$LOG")
if [ "$killed" -ge 8 ]; then
    echo "OK   coverage: $killed window(s) undone by transaction state"
else
    echo "DIFF coverage: only [$killed] windows undone by state - the image path is back"
    fail=1
fi

# --- 10. AND THE ENGINE ACCEPTS THE FILE --------------------------------
# The nested ids are ordinary TIP entries or they are corruption, and
# `gfix -v -full` is what says which.
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1 | tr -d ' \n')
if [ -z "$v" ]; then
    echo "OK   gfix -v -full accepts fire-crab's file"
else
    echo "DIFF gfix -v -full: [$v]"; fail=1
fi
both "and both files hold the same table" "SET HEADING OFF;
SELECT COUNT(*) || '/' || SUM(V) FROM T;"

echo "ran $ran checks"
exit $fail
