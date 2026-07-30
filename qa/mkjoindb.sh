#!/bin/bash
# Build the JOIN SCRATCH DATABASE that qa/serve-real-{join,outerjoin,
# project,insert,syscat}.sh expect, and gbak-restore a clean copy of it.
#
# Those gates were written against a database that lived in one
# workspace and nowhere else, so they had been failing for want of it -
# a gate nobody can run is a gate that stops telling the truth. This
# builds it from a script, so they are self-sufficient.
#
# The shape is chosen by what the joins must PROVE, not by realism:
#
#   DEPT(ID, REGION_ID, NAME)   - 8 rows, and DEPT 8 has NO employees, so
#                                 a LEFT join from DEPT is padded there
#                                 and an INNER join drops it.
#   EMP(ID, DEPT_ID, REGION_ID, SALARY, NAME)
#                               - 100 rows. Two DEPT_IDs are NULL (a NULL
#                                 key never joins, so it surfaces as a
#                                 padded row and never as a match) and
#                                 one is DANGLING - 99, which no DEPT row
#                                 has - so an INNER join must drop it
#                                 while a LEFT join keeps it padded.
#                                 REGION_ID agrees with the department's
#                                 for most rows and disagrees for a few,
#                                 so a two-column ON is not the same
#                                 join as a one-column ON.
#   NL / NR(K, G, ...)          - two tables sharing K and G by NAME, for
#                                 NATURAL JOIN: only one pair agrees on
#                                 both, and a row where both shared
#                                 columns are NULL never joins.
#   REGION(ID, NAME)            - 5 rows, one of which (50) no department
#                                 references, so a three-table chain has
#                                 something to drop at its second step.
#   J1(K CHAR(10), V) / J2(K2 VARCHAR(10), W)
#                               - text keys: duplicates on both sides (so
#                                 a match is a small cross product, and
#                                 a join that emitted one row per left
#                                 row would look right until counted),
#                                 a NULL key on each side, and CHAR-vs-
#                                 VARCHAR padding, which must compare
#                                 pad-insensitively.
#
#   qa/mkjoindb.sh [path]        (default /tmp/fbhandson/joindb.fdb)
#
# Prints the path of the CLEAN restored copy, which is what the gates
# want - they compare fire-crab against isql over the same file, and a
# gbak round trip is what makes the file's state predictable.

set -u
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
SRC="${1:-/tmp/fbhandson/joindb.fdb}"
DIR=$(dirname "$SRC")
BASE=$(basename "$SRC" .fdb)
FBK="$DIR/$BASE.fbk"
CLEAN="$DIR/${BASE}_clean.fdb"

mkdir -p "$DIR"
rm -f "$SRC" "$FBK" "$CLEAN"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create" >&2; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE DEPT (
  ID INTEGER NOT NULL PRIMARY KEY,
  REGION_ID INTEGER,
  NAME VARCHAR(30)
);
CREATE TABLE EMP (
  ID INTEGER NOT NULL PRIMARY KEY,
  DEPT_ID INTEGER,
  REGION_ID INTEGER,
  SALARY INTEGER,
  NAME VARCHAR(30)
);
CREATE TABLE REGION (
  ID INTEGER NOT NULL PRIMARY KEY,
  NAME VARCHAR(20)
);
-- two tables built for NATURAL JOIN: they share K and G by name (so the
-- derived condition has two terms), each has a column of its own, and a
-- row where both shared columns are NULL - which never joins, because
-- NULL = NULL is UNKNOWN
CREATE TABLE NL (K INTEGER, G INTEGER, LONLY VARCHAR(6));
CREATE TABLE NR (K INTEGER, G INTEGER, RONLY VARCHAR(6));
CREATE TABLE J1 (K CHAR(10), V INTEGER);
CREATE TABLE J2 (K2 VARCHAR(10), W INTEGER);
COMMIT;

INSERT INTO DEPT VALUES (1, 10, 'Engineering');
INSERT INTO DEPT VALUES (2, 10, 'Sales');
INSERT INTO DEPT VALUES (3, 20, 'Support');
INSERT INTO DEPT VALUES (4, 20, 'Finance');
INSERT INTO DEPT VALUES (5, 30, 'Legal');
INSERT INTO DEPT VALUES (6, 30, 'Facilities');
INSERT INTO DEPT VALUES (7, 40, 'Research');
INSERT INTO DEPT VALUES (8, 40, 'Archive');
COMMIT;

-- the THIRD table of a chain: every department's region exists, and
-- region 50 belongs to none, so a three-table inner join drops it and
-- an outer one keeps it
INSERT INTO REGION VALUES (10, 'North');
INSERT INTO REGION VALUES (20, 'South');
INSERT INTO REGION VALUES (30, 'East');
INSERT INTO REGION VALUES (40, 'West');
INSERT INTO REGION VALUES (50, 'Nowhere');
COMMIT;

-- text join keys: duplicates on both sides, a NULL each, and the
-- CHAR/VARCHAR padding difference
INSERT INTO NL VALUES (1, 10, 'l1');
INSERT INTO NL VALUES (2, 20, 'l2');
INSERT INTO NL VALUES (3, 30, 'l3');
INSERT INTO NL VALUES (4, NULL, 'l4');
INSERT INTO NR VALUES (1, 10, 'r1');
INSERT INTO NR VALUES (2, 99, 'r2');
INSERT INTO NR VALUES (5, 50, 'r5');
INSERT INTO NR VALUES (4, NULL, 'r4');
INSERT INTO J1 VALUES ('alpha', 1);
INSERT INTO J1 VALUES ('alpha', 2);
INSERT INTO J1 VALUES ('beta', 3);
INSERT INTO J1 VALUES ('gamma', 4);
INSERT INTO J1 VALUES (NULL, 5);
INSERT INTO J2 VALUES ('alpha', 10);
INSERT INTO J2 VALUES ('alpha', 20);
INSERT INTO J2 VALUES ('beta', 30);
INSERT INTO J2 VALUES ('delta', 40);
INSERT INTO J2 VALUES (NULL, 50);
COMMIT;
EOF

# 100 employees: ids 1..100, department (id mod 7) + 1 so DEPT 8 keeps
# none, salaries spread across the WHERE thresholds the gates use.
{
  echo "SET TERM ;"
  i=1
  while [ $i -le 100 ]; do
    dept=$(( (i % 7) + 1 ))
    region=$(( ((dept - 1) / 2) * 10 + 10 ))
    # a few rows whose REGION_ID disagrees with their department's, so a
    # two-column ON selects strictly fewer rows than a one-column one
    if [ $((i % 17)) -eq 0 ]; then region=$((region + 10)); fi
    sal=$(( 1000 + i * 45 ))
    case $i in
      # two NULL keys and one dangling department
      13|41) echo "INSERT INTO EMP VALUES ($i, NULL, $region, $sal, 'emp$i');" ;;
      67)    echo "INSERT INTO EMP VALUES ($i, 99, $region, $sal, 'emp$i');" ;;
      *)     echo "INSERT INTO EMP VALUES ($i, $dept, $region, $sal, 'emp$i');" ;;
    esac
    i=$((i + 1))
  done
  echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" "$SRC" >/dev/null 2>&1 || {
    echo "FAIL populate" >&2; exit 1; }

# the gates want a CLEAN (gbak-restored) copy: a round trip normalises
# the file's page state, so what they read is not one workspace's history
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$FBK" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$CLEAN" >/dev/null 2>&1 || {
    echo "FAIL gbak round trip" >&2; exit 1; }
chmod 666 "$CLEAN" 2>/dev/null

# teeth: the properties the joins are built on must actually hold
check=$("$ISQL" -q -b -user "$U" -pas "$P" "$CLEAN" <<'EOF' 2>&1
SET HEADING OFF;
SELECT COUNT(*) FROM EMP;
SELECT COUNT(*) FROM DEPT;
SELECT COUNT(*) FROM EMP WHERE DEPT_ID IS NULL;
SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM DEPT D WHERE D.ID = E.DEPT_ID);
SELECT COUNT(*) FROM DEPT D WHERE NOT EXISTS (SELECT 1 FROM EMP E WHERE E.DEPT_ID = D.ID);
SELECT COUNT(*) FROM REGION R WHERE NOT EXISTS (SELECT 1 FROM DEPT D WHERE D.REGION_ID = R.ID);
EOF
)
set -- $check
if [ "$1" = "100" ] && [ "$2" = "8" ] && [ "$3" = "2" ] && [ "$4" = "1" ] && [ "$5" = "1" ] \
   && [ "$6" = "1" ]; then
    echo "$CLEAN"
else
    echo "FAIL fixture properties: emp=$1 dept=$2 null_keys=$3 dangling=$4 empty_dept=$5 empty_region=$6" >&2
    exit 1
fi
