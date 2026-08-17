#!/bin/bash
# ACCESS-PATH SELECTION, oracle number five: the engine's own PLAN.
# `SET PLANONLY ON` makes the engine PREPARE a statement and print the
# plan it chose - which index fetches the rows, whether an ORDER BY
# rides an index's order or needs a sort - without executing anything.
# That is a complete, textual statement of the optimizer's decision,
# and `fcopt plan` must print the SAME LINE for the SAME statement.
#
# The battery walks the decision surface: no predicate, matchable and
# unmatchable comparisons, AND/OR structure, indexed and unindexed
# columns, navigation with and without a direction match, and the
# SORT wrapper. Refusals (joins, unions, subqueries, multi-column
# ORDER) must answer REFUSED - a plan this crate cannot justify is
# never printed.
#
#   qa/opt-plans.sh
#
# Builds its own scratch database.

set -u
FCOPT="${FCOPT:-$(dirname "$0")/../target/release/fcopt}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-optplans.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(20), NOTE VARCHAR(20));
CREATE TABLE U (UID INTEGER, UA INTEGER);
CREATE INDEX IDX_T_ID ON T (ID);
CREATE INDEX IDX_T_AMT ON T (AMT);
CREATE INDEX IDX_T_NAME ON T (NAME);
CREATE DESCENDING INDEX IDX_T_AMT_D ON T (AMT);
CREATE INDEX IDX_U_UID ON U (UID);
CREATE TABLE C (X INTEGER, Y INTEGER, Z INTEGER);
CREATE INDEX IDX_C_XY ON C (X, Y);
-- a SKEWED compound index with real rows: 5000 rows, 10 distinct X, so
-- the whole-index statistic (0.0002) and segment 0's (0.1) are 500x
-- apart. Nothing else in this fixture can tell the two readings apart.
CREATE TABLE CS (X INTEGER, Y INTEGER);
CREATE TABLE SMALLT (X INTEGER);
CREATE INDEX IDX_CS_XY ON CS (X, Y);
CREATE INDEX IDX_SMALLT_X ON SMALLT (X);
-- TP is POPULATED with two single-column indexes and an unindexed
-- column: the fixture for the OR-union spelling and the navigate-vs-sort
-- decision, which flips between an empty table (T above) and a real one
CREATE TABLE TP (PID INTEGER, PAMT INTEGER, PK INTEGER);
CREATE INDEX IDX_TP_PID ON TP (PID);
CREATE INDEX IDX_TP_PAMT ON TP (PAMT);
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 500) DO BEGIN I = I + 1; INSERT INTO TP VALUES (:I, MOD(:I,50), :I); END
END^
SET TERM ; ^
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 5000) DO BEGIN I = I + 1; INSERT INTO CS VALUES (MOD(:I,10), :I); END
  I = 0;
  WHILE (I < 200) DO BEGIN I = I + 1; INSERT INTO SMALLT VALUES (MOD(:I,200)); END
END^
SET TERM ; ^
COMMIT;
SET STATISTICS INDEX IDX_CS_XY;
SET STATISTICS INDEX IDX_SMALLT_X;
COMMIT;
EOF

fail=0
check() { # <sql> - the engine's plan must equal fcopt's
    want=$("$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$1;
SQL
)
    got=$("$FCOPT" plan "$DB" "$1" 2>&1)
    if [ "$got" = "$want" ]; then
        echo "OK   $1"
        echo "     $got"
    else
        echo "DIFF $1"
        echo "     engine: $want"
        echo "     fcopt:  $got"
        fail=1
    fi
}
refuse() { # <sql> - outside the slice: fcopt must refuse
    got=$("$FCOPT" plan "$DB" "$1" 2>&1)
    case "$got" in
        REFUSED*) echo "OK   refused: $1" ;;
        *) echo "DIFF [$1] expected REFUSED, got: $got"; fail=1 ;;
    esac
}

# --- no predicate, and unusable ones -> NATURAL ------------------------
check "SELECT ID FROM T"
check "SELECT COUNT(*) FROM T"
check "SELECT ID FROM T WHERE NOTE = 'x'"
check "SELECT ID FROM T WHERE ID <> 5"
check "SELECT ID FROM T WHERE ID IS NOT NULL"
check "SELECT ID FROM T WHERE NAME LIKE '%a'"

# --- matchable comparisons -> INDEX -----------------------------------
check "SELECT ID FROM T WHERE ID = 5"
check "SELECT ID FROM T WHERE AMT > 3"
check "SELECT ID FROM T WHERE AMT <= 3"
check "SELECT ID FROM T WHERE ID BETWEEN 1 AND 9"
check "SELECT ID FROM T WHERE ID IS NULL"
check "SELECT ID FROM T WHERE NAME STARTING WITH 'a'"
check "SELECT ID FROM T WHERE NAME LIKE 'a%'"

# --- AND / OR structure ------------------------------------------------
check "SELECT ID FROM T WHERE ID = 5 AND AMT = 3"
check "SELECT ID FROM T WHERE ID = 5 AND AMT = 3 AND NAME = 'x'"
check "SELECT ID FROM T WHERE ID = 5 AND NOTE = 'x'"
check "SELECT ID FROM T WHERE ID = 5 OR AMT = 3"
check "SELECT ID FROM T WHERE ID = 5 OR NOTE = 'x'"

# --- navigation, direction matching, and the SORT wrapper -------------
check "SELECT ID FROM T ORDER BY ID"
check "SELECT ID FROM T ORDER BY AMT"
check "SELECT ID FROM T ORDER BY AMT DESC"
check "SELECT ID FROM T ORDER BY ID DESC"
check "SELECT ID FROM T ORDER BY NOTE"
check "SELECT ID FROM T WHERE ID > 3 ORDER BY ID"
check "SELECT ID FROM T WHERE AMT > 3 ORDER BY ID"
check "SELECT ID FROM T WHERE NOTE = 'x' ORDER BY ID"

# --- two-stream joins: order, swap, hash ------------------------------
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID"
check "SELECT A.UID FROM U A JOIN T B ON A.UID = B.ID"
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UA"
check "SELECT A.UA FROM U A JOIN U B ON A.UA = B.UA"
check "SELECT A.ID FROM T A JOIN U B ON A.NAME = B.UA"
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UID"
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UA"
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID WHERE A.AMT = 3"
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UID WHERE A.AMT = 3"
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID WHERE B.UA = 7"
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID ORDER BY A.ID"
check "SELECT A.ID FROM T A, U B WHERE A.ID = B.UID"

# --- compound indexes: the leading-segment (prefix) rule ---------------
check "SELECT X FROM C WHERE X = 1"
check "SELECT X FROM C WHERE Y = 2"
check "SELECT X FROM C WHERE X = 1 AND Y = 2"
check "SELECT X FROM C WHERE X = 1 AND Z = 3"
check "SELECT X FROM C WHERE X > 1 AND Y = 2"
check "SELECT X FROM C ORDER BY X"
check "SELECT X FROM C ORDER BY X, Y"
# THE MATCHED SEGMENT'S SELECTIVITY, NOT THE WHOLE INDEX'S.
# `RDB$INDICES.RDB$STATISTICS` is the figure for the whole key; the
# engine costs a retrieval with the figure for the segments the
# predicate actually MATCHED. On a compound index over a skewed leading
# column they differ by orders of magnitude - reading the whole-index
# one made a keyed loop look far cheaper than it is and produced a plan
# the engine does not choose. These need REAL ROWS and fresh statistics,
# which the fixture below provides.
check "SELECT X FROM CS WHERE X = 1"
check "SELECT X FROM CS WHERE X = 1 AND Y = 2"
check "SELECT S.X FROM SMALLT S JOIN CS ON CS.X = S.X"
check "SELECT S.X FROM SMALLT S LEFT JOIN CS ON CS.X = S.X"
check "SELECT X FROM C ORDER BY X, Z"
check "SELECT X FROM C ORDER BY Y"
check "SELECT X FROM C ORDER BY X DESC"

# --- chains of three streams -------------------------------------------
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID JOIN C D ON D.X = B.UID"
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID JOIN C D ON D.X = B.UID WHERE A.AMT = 3"

# --- equivalence classes: the reordering, converted -------------------
# `D.Z = B.UID` and `A.ID = B.UID` put A.ID, B.UID and D.Z in ONE
# class, so the unindexable link DRIVES and the rest follow SQL order
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID JOIN C D ON D.Z = B.UID"
check "SELECT A.ID FROM C D JOIN U B ON D.Z = B.UID JOIN T A ON A.ID = B.UID"
check "SELECT A.ID FROM T A JOIN C D ON A.ID = D.Z JOIN U B ON B.UID = D.Z"
check "SELECT A.ID FROM T A JOIN U B ON A.AMT = B.UA JOIN C D ON D.X = B.UA"
# ...and the order transfers through the class too
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID ORDER BY B.UID"

# --- the retrieval cost: a UNIQUE lookup is a fixed 4 -----------------
# With BOTH join keys indexed, both arrangements are legal and the engine
# takes the cheaper. Retrieval.cpp prices a unique equality lookup at a
# FIXED DEFAULT_INDEX_COST + 1 = 4 ("independent from a possibly outdated
# statistics") while a non-unique one costs 3 + cardinality * selectivity
# - so on a database whose statistics are zero the NON-unique index is
# cheaper, and the engine drives the stream a reader would have made the
# inner one. Symmetric pairs keep the SQL order, because the engine
# replaces its best arrangement only on a STRICTLY smaller cost.
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID"
check "SELECT A.UID FROM U A JOIN T B ON A.UID = B.ID"

# --- outer joins: the KIND decides who drives -------------------------
# An outer join makes a plan NODE, so a chain NESTS where an inner chain
# of the same streams would have flattened into one JOIN list - the
# preserved side and its optional side are one result the next join sees
# as a unit.
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UID LEFT JOIN C D ON D.X = B.UID"
check "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID LEFT JOIN C D ON D.X = B.UID"
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UID JOIN C D ON D.X = B.UID"
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UA LEFT JOIN C D ON D.X = B.UA"
# RIGHT is LEFT with the sides exchanged: the PRESERVED side drives, so
# the plan is the swapped one - not the left-driving one
check "SELECT A.ID FROM T A RIGHT JOIN U B ON A.ID = B.UID"
check "SELECT A.ID FROM U B RIGHT JOIN T A ON A.ID = B.UID"
# FULL is BOTH directions, and the engine says so: JOIN (JOIN(...), JOIN(...))
check "SELECT A.ID FROM T A FULL JOIN U B ON A.ID = B.UID"
check "SELECT A.ID FROM T A FULL JOIN U B ON A.ID = B.UA"
# an outer join with a driving filter still filters the DRIVER
check "SELECT A.ID FROM T A LEFT JOIN U B ON A.ID = B.UID LEFT JOIN C D ON D.X = B.UID WHERE A.AMT = 3"

# --- outside the slice -------------------------------------------------
refuse "SELECT ID FROM T UNION ALL SELECT UID FROM U"
refuse "SELECT ID FROM T WHERE ID IN (SELECT UID FROM U)"
# a FULL or RIGHT join INSIDE a chain: the nesting is converted, the
# direction-swap inside a chain is not
refuse "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID FULL JOIN C D ON D.X = B.UID"
refuse "SELECT A.ID FROM T A JOIN U B ON A.ID = B.UID RIGHT JOIN C D ON D.X = B.UID"

# ======================================================================
# PHASE 2: the COST BOUNDARY, on a POPULATED database
# ======================================================================
# Single-table access paths are STRUCTURAL - the same plans come back
# with three thousand rows as with none. JOIN plans are not: with data
# the engine drives the SMALLER stream regardless of SQL order, and
# above a modest size it HASHES even when both sides are indexed. This
# crate measures rather than guesses: it plans single-table paths at
# any size and REFUSES populated joins, and this phase pins both
# halves - the plans that must still match, and the engine's own
# answers beside the refusals.
DBP="$D/fc-optcost.fdb"
rm -f "$DBP"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create populated"; exit 1; }
CREATE DATABASE '$DBP' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE BIG (K INTEGER, FLAT INTEGER, UNIQ INTEGER);
CREATE INDEX IDX_BIG_FLAT ON BIG (FLAT);
CREATE INDEX IDX_BIG_UNIQ ON BIG (UNIQ);
CREATE TABLE SMALL (S INTEGER);
CREATE INDEX IDX_SMALL_S ON SMALL (S);
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER; BEGIN I = 0; WHILE (I < 3000) DO BEGIN INSERT INTO BIG VALUES (:I, 1, :I); I = I + 1; END END^
EXECUTE BLOCK AS DECLARE I INTEGER; BEGIN I = 0; WHILE (I < 5) DO BEGIN INSERT INTO SMALL VALUES (:I); I = I + 1; END END^
SET TERM ; ^
COMMIT;
EOF

pcheck() { # <sql> - single-table paths must match WITH data
    want=$("$ISQL" -q -user "$U" -pas "$P" "$DBP" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$1;
SQL
)
    got=$("$FCOPT" plan "$DBP" "$1" 2>&1)
    if [ "$got" = "$want" ]; then
        echo "OK   (populated) $1"
    else
        echo "DIFF (populated) $1"
        echo "     engine: $want"
        echo "     fcopt:  $got"
        fail=1
    fi
}
pcheck "SELECT K FROM BIG WHERE FLAT = 1"
pcheck "SELECT K FROM BIG WHERE UNIQ = 7"
pcheck "SELECT K FROM BIG WHERE K = 1"
pcheck "SELECT K FROM BIG ORDER BY UNIQ"
pcheck "SELECT K FROM BIG WHERE FLAT = 1 AND UNIQ = 7"
pcheck "SELECT COUNT(*) FROM BIG"
# the cost cases: the engine drives the SMALL side regardless of SQL
# order. These sat behind prefuse while the crate refused populated
# joins; it plans them now, so the check is the stronger one - the plan
# must BE the engine's, either way round
pcheck "SELECT A.K FROM BIG A JOIN SMALL B ON A.UNIQ = B.S"
pcheck "SELECT B.S FROM SMALL B JOIN BIG A ON A.UNIQ = B.S"

# ======================================================================
# PHASE 3: the CARDINALITY GRID - 36 cells, and never a wrong plan
# ======================================================================
# THIRTEEN tables - 0, 1, 2, 5, 8, 20, 30, 50, 120, 500, 900, 3000 and
# 5000 rows - joined every way round: 169 cells. For each, fcopt must
# either MATCH the engine's plan or REFUSE. A wrong plan anywhere fails
# the gate. That is the property that matters for a cost model only
# partly converted: silence where it does not know, exactness where it
# does.
#
# THE SIZE SET IS THE GATE. It used to be {0, 1, 5, 50, 500, 3000}, and
# that set has a HOLE FROM 5 TO 50 that straddles the engine's HASH/loop
# crossover - so a model could score 36/36 on it while being wrong at
# every cardinality between. It was: against this widened set the old
# model scores 153/169, and all sixteen of its errors are in the 2-120
# band the narrow set skipped. A grid that cannot fail is not a grid.
DBG="$D/fc-optgrid.fdb"
rm -f "$DBG"
{
  echo "CREATE DATABASE '$DBG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  for n in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
      echo "CREATE TABLE G$n (V INTEGER); CREATE INDEX IDX_G$n ON G$n (V);"
  done
  echo "COMMIT;"
  echo "SET TERM ^ ;"
  for n in 1 5 50 500 3000; do
      echo "EXECUTE BLOCK AS DECLARE I INTEGER; BEGIN I=0; WHILE (I<$n) DO BEGIN INSERT INTO G$n VALUES(:I); I=I+1; END END^"
  done
  echo "SET TERM ; ^"
  echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create grid"; exit 1; }

# with FRESH statistics the cost model must be EXACT everywhere;
# without them the crate must refuse rather than guess
for n in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
    "$ISQL" -q -b -user "$U" -pas "$P" "$DBG" >/dev/null 2>&1 <<SQL
SET STATISTICS INDEX IDX_G$n;
COMMIT;
SQL
done
matched=0; refused=0; wrong=0
for o in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
  for i in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
    q="SELECT A.V FROM G$o A JOIN G$i B ON A.V = B.V"
    eng=$("$ISQL" -q -user "$U" -pas "$P" "$DBG" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$q;
SQL
)
    got=$("$FCOPT" plan "$DBG" "$q" 2>&1)
    if [ "$got" = "$eng" ]; then
        matched=$((matched + 1))
    elif [ "${got:0:7}" = "REFUSED" ]; then
        refused=$((refused + 1))
    else
        echo "DIFF grid cell ($o x $i)"
        echo "     engine: $eng"
        echo "     fcopt:  $got"
        wrong=$((wrong + 1))
    fi
  done
done
if [ $wrong -eq 0 ] && [ $matched -eq 169 ]; then
    echo "OK   cost grid (FRESH statistics): all 169 cells planned EXACTLY"
elif [ $wrong -eq 0 ]; then
    echo "DIFF cost grid: only $matched of 169 exact ($refused refused) - the cost model regressed"
    fail=1
else
    echo "DIFF cost grid: $wrong cells planned WRONGLY"
    fail=1
fi

# ======================================================================
# PHASE 4: the same grid with STALE statistics - refuse, never guess
# ======================================================================
# The engine keeps costing with a zero selectivity (it does not
# recompute silently), and its behaviour then depends on internal state
# this crate has not converted. Every populated cell must REFUSE.
DBS="$D/fc-optstale.fdb"
rm -f "$DBS"
{
  echo "CREATE DATABASE '$DBS' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  for n in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
      echo "CREATE TABLE G$n (V INTEGER); CREATE INDEX IDX_G$n ON G$n (V);"
  done
  echo "COMMIT;"
  echo "SET TERM ^ ;"
  for n in 1 5 50 500 3000; do
      echo "EXECUTE BLOCK AS DECLARE I INTEGER; BEGIN I=0; WHILE (I<$n) DO BEGIN INSERT INTO G$n VALUES(:I); I=I+1; END END^"
  done
  echo "SET TERM ; ^"
  echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create stale"; exit 1; }
swrong=0; srefused=0; smatched=0
for o in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
  for i in 0 1 2 5 8 20 30 50 120 500 900 3000 5000; do
    q="SELECT A.V FROM G$o A JOIN G$i B ON A.V = B.V"
    eng=$("$ISQL" -q -user "$U" -pas "$P" "$DBS" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$q;
SQL
)
    got=$("$FCOPT" plan "$DBS" "$q" 2>&1)
    if [ "$got" = "$eng" ]; then smatched=$((smatched + 1))
    elif [ "${got:0:7}" = "REFUSED" ]; then srefused=$((srefused + 1))
    else
        echo "DIFF stale-grid cell ($o x $i)"
        echo "     engine: $eng"
        echo "     fcopt:  $got"
        swrong=$((swrong + 1))
    fi
  done
done
# THE LENIENCY IS GONE. This phase used to pass on "zero wrong" however
# many cells were REFUSED - the right rule while the crate declined to
# cost a zero statistic, and the wrong one now that it substitutes
# DEFAULT_SELECTIVITY like the engine (Retrieval.cpp:1019-1026). A model
# that refuses everything must not score a clean sheet, so the stale grid
# is now held to the same standard as the fresh one: every cell exact,
# nothing refused.
if [ $swrong -eq 0 ] && [ $srefused -eq 0 ] && [ $smatched -eq 169 ]; then
    echo "OK   stale-statistics grid: all 169 cells planned EXACTLY, zero refused"
elif [ $swrong -eq 0 ]; then
    echo "DIFF stale-statistics grid: $smatched exact but $srefused REFUSED - the engine answers every one"
    fail=1
else
    echo "DIFF stale-statistics grid: $swrong cells planned WRONGLY"
    fail=1
fi

# ==== a FIFTH database: ASYMMETRIC index kinds =========================
# The four databases above all pair like with like - both sides of a join
# indexed the same way - so they never asked which of a UNIQUE and a
# NON-UNIQUE inner lookup the engine prefers. Retrieval.cpp prices the
# unique one at a FIXED 4 ("independent from a possibly outdated
# statistics") and the other at 3 + cardinality * selectivity, so on a
# database whose statistics are zero the NON-unique index is cheaper and
# the engine drives the stream a reader would have made the inner one.
# Both wrong answers this database found had been passing for six slices.
DBA="$D/fc-optuniq.fdb"
rm -f "$DBA"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL asymmetric db"; exit 1; }
CREATE DATABASE '$DBA' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER PRIMARY KEY, BX INTEGER, N INTEGER);
CREATE TABLE B (ID INTEGER PRIMARY KEY, CX INTEGER, N INTEGER);
CREATE TABLE C (ID INTEGER PRIMARY KEY, N INTEGER);
CREATE INDEX A_BX ON A (BX);
CREATE INDEX B_CX ON B (CX);
COMMIT;
EOF

acheck() { # <sql> - against the asymmetric database
    q="$1"
    eng=$("$ISQL" -q -user "$U" -pas "$P" "$DBA" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$q;
SQL
)
    got=$("$FCOPT" plan "$DBA" "$q" 2>&1)
    if [ "$got" = "$eng" ]; then
        echo "OK   [$q] $got"
    else
        echo "DIFF [$q]"
        echo "     engine: $eng"
        echo "     fcopt:  $got"
        fail=1
    fi
}

# a NON-unique index on one side, a primary key on the other: the engine
# drives the same stream in BOTH SQL orders, because the cost - not the
# text - decides
acheck "SELECT A.ID FROM A JOIN B ON A.BX = B.ID"
acheck "SELECT A.ID FROM B JOIN A ON A.BX = B.ID"
# a chain of two such links: the far end drives, because two non-unique
# lookups (3 + 3) beat two unique ones (4 + 4)
acheck "SELECT A.ID FROM A JOIN B ON A.BX = B.ID JOIN C ON B.CX = C.ID"
# the outer-join laws hold on this database too
acheck "SELECT A.ID FROM A LEFT JOIN B ON A.BX = B.ID"
acheck "SELECT A.ID FROM A RIGHT JOIN B ON A.BX = B.ID"
acheck "SELECT A.ID FROM A FULL JOIN B ON A.BX = B.ID"
acheck "SELECT A.ID FROM A LEFT JOIN B ON A.BX = B.ID LEFT JOIN C ON B.CX = C.ID"

# --- the OR union's spelling, and navigate-vs-sort ---------------------
# An OR is ONE INVERSION PER BRANCH, listed in BRANCH order - the same
# index twice for two branches on it, and `PAMT = 2 OR PID = 5` prints
# PAMT first. An AND's conjuncts on one index combine and print once.
check "SELECT PID FROM TP WHERE PID = 5 OR PID = 7"
check "SELECT PID FROM TP WHERE PAMT = 2 OR PID = 5"
check "SELECT PID FROM TP WHERE PID = 5 OR PID = 7 OR PID = 9"
# Navigation on a POPULATED table rides any fully-indexed filter, its
# other inversions listed beside it (`ORDER ... INDEX (...)`); an
# unindexed conjunct sends the plan to the SORT. On the EMPTY T above the
# same shapes sort whenever anything is listed - the engine's
# applyNavigation cost flip, measured on both fixtures.
check "SELECT PID FROM TP WHERE PAMT = 2 ORDER BY PID"
check "SELECT PID FROM TP WHERE PAMT > 3 ORDER BY PID"
check "SELECT PID FROM TP WHERE PID = 5 OR PID = 7 ORDER BY PID"
check "SELECT PID FROM TP WHERE PAMT = 2 OR PAMT = 3 ORDER BY PID"
check "SELECT PID FROM TP WHERE PID = 5 AND PAMT = 2 ORDER BY PID"
check "SELECT PID FROM TP WHERE PK = 9 ORDER BY PID"
check "SELECT PID FROM TP WHERE PK = 9 AND PID = 5 ORDER BY PID"
check "SELECT PID FROM TP WHERE PID = 5 OR PK = 9 ORDER BY PID"
check "SELECT PID FROM TP WHERE PID = 5 ORDER BY PID"
# ... and the EMPTY-table side of the flip, on T
check "SELECT ID FROM T WHERE AMT = 2 ORDER BY ID"
check "SELECT ID FROM T WHERE ID = 5 OR ID = 7 ORDER BY ID"
# the applyNavigation COST arithmetic proper: a bare ORDER BY navigates
# on the populated table (the 500-row quicksort loses to the walk) and
# FIRST enters first-rows mode, which skips the sort outright - the
# size-flip's other cells (a 6-row table sorting bare, SKIP not being
# first-rows) are pinned in serve-real-index.sh over its live fixture
check "SELECT PID FROM TP ORDER BY PID"
check "SELECT FIRST 3 PID FROM TP ORDER BY PID"
check "SELECT FIRST 3 PID FROM TP WHERE PAMT = 2 ORDER BY PID"

exit $fail
