#!/bin/bash
# READ COMMITTED READ CONSISTENCY - isql's default isolation, and what
# the engine runs for its default TPB (read committed / no record
# version, which the engine upgrades under the ReadConsistency setting -
# measured MON$ISOLATION_MODE = 4). Two laws come out of it, both
# measured against the live engine before conversion:
#
#   * A STATEMENT'S VIEW IS FIXED AT ITS START. A row an autonomous
#     block commits in the MIDDLE of a statement is not seen by the rest
#     of that statement - a procedure that commits a row autonomously
#     and then counts it answers 0.
#   * A TRANSACTION NEVER SEES ITS OWN BLOCK'S COMMIT. Not even a LATER
#     statement of the same transaction sees the row - though a fresh
#     transaction does, and an INDEPENDENT concurrent commit of the same
#     age would. The launching transaction holds its own autonomous ids
#     out of every view it takes.
#
# The second law reaches back versions too: an autonomous UPDATE is
# invisible, so the launcher reads the row's OLD committed value, not the
# block's new one.
#
#   qa/serve-real-readconsistency.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4738}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-rc-$PORT.log"
fail=0; ran=0
mkdir -p "$D"

build() {
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE LOG (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO LOG (ID, V) VALUES (1, 100);
COMMIT;
SET TERM ^;
CREATE PROCEDURE RC_INS RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    INSERT INTO LOG (ID, V) VALUES (12, 1200);
  SELECT COUNT(*) FROM LOG WHERE ID = 12 INTO :N;
END^
CREATE PROCEDURE RC_UPD RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
    UPDATE LOG SET V = 999 WHERE ID = 1;
  SELECT V FROM LOG WHERE ID = 1 INTO :N;
END^
CREATE PROCEDURE RC_NEST RETURNS (N INTEGER) AS
BEGIN
  IN AUTONOMOUS TRANSACTION DO
  BEGIN
    INSERT INTO LOG (ID, V) VALUES (20, 2000);
    IN AUTONOMOUS TRANSACTION DO
      INSERT INTO LOG (ID, V) VALUES (21, 2100);
  END
  SELECT COUNT(*) FROM LOG WHERE ID IN (20, 21) INTO :N;
END^
SET TERM ;^
COMMIT;
EOF
}
DBE="$D/fc-rc-e.fdb"
DBF="$D/fc-rc-f.fdb"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
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
# an autonomous COMMIT is durable and a ROLLBACK does not undo it, so
# every check starts from a FRESH pair of databases - otherwise the rows
# one check's block commits would pollute the next one's counts (the two
# servers would still agree, but on meaningless growing numbers)
both() { # <label> <sql> - engine and fc must agree, on a clean database
    local e c
    rm -f "$DBE" "$DBF"
    build "localhost:$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF" 2>/dev/null
    e=$(eng "$2"); c=$(crab "$2")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi
}

# --- law 1: the statement's view is fixed at its start ------------------------
both "an autonomous INSERT is invisible inside the same statement" "SET HEADING OFF;
EXECUTE PROCEDURE RC_INS;
ROLLBACK;"
# and an autonomous UPDATE too - the launcher reads the OLD value (a
# back version), never the block's new one
both "an autonomous UPDATE leaves the launcher the old value" "SET HEADING OFF;
EXECUTE PROCEDURE RC_UPD;
ROLLBACK;"
both "a nested block is invisible to its launcher too" "SET HEADING OFF;
EXECUTE PROCEDURE RC_NEST;
ROLLBACK;"

# --- law 2: not even a later statement of the same transaction sees it --------
both "a later statement of the SAME transaction still does not see the row" "SET HEADING OFF;
EXECUTE PROCEDURE RC_INS;
SELECT COUNT(*) FROM LOG WHERE ID = 12;
ROLLBACK;"
both "...and still reads the row's old value after the block updated it" "SET HEADING OFF;
EXECUTE PROCEDURE RC_UPD;
SELECT V FROM LOG WHERE ID = 1;
ROLLBACK;"

# --- but a FRESH transaction sees what the block committed --------------------
# the block's rows are durable; only the launcher is blind to them. A new
# transaction (after the launcher commits) counts them.
both "a fresh transaction sees the block's INSERT" "SET HEADING OFF;
EXECUTE PROCEDURE RC_INS;
COMMIT;
SELECT COUNT(*) FROM LOG WHERE ID = 12;"
both "a fresh transaction sees the block's UPDATE" "SET HEADING OFF;
EXECUTE PROCEDURE RC_UPD;
COMMIT;
SELECT V FROM LOG WHERE ID = 1;"

# --- the ordinary read is unmoved: a statement sees prior committed rows ------
# the pre-existing row was committed long before this statement began, so
# the statement view - fixed at its start - counts it, as it always did.
both "the statement view still sees rows committed before it began" "SET HEADING OFF;
SELECT V FROM LOG WHERE ID = 1;"

echo "ran $ran checks"
exit $fail
