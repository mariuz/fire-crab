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
prefuse() { # <sql> - a populated JOIN: fcopt refuses, and we RECORD
           # the engine's own plan so the frontier is documented
    eng=$("$ISQL" -q -user "$U" -pas "$P" "$DBP" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$1;
SQL
)
    got=$("$FCOPT" plan "$DBP" "$1" 2>&1)
    case "$got" in
        REFUSED*)
            echo "OK   (populated) refused, engine says: $eng" ;;
        *)
            echo "DIFF (populated) [$1] expected REFUSED, got: $got"; fail=1 ;;
    esac
}

pcheck "SELECT K FROM BIG WHERE FLAT = 1"
pcheck "SELECT K FROM BIG WHERE UNIQ = 7"
pcheck "SELECT K FROM BIG WHERE K = 1"
pcheck "SELECT K FROM BIG ORDER BY UNIQ"
pcheck "SELECT K FROM BIG WHERE FLAT = 1 AND UNIQ = 7"
pcheck "SELECT COUNT(*) FROM BIG"
# the cost cases: the engine drives the SMALL side, and hashes when
# both sides grow - fcopt refuses both rather than guess
# the cost cases in the BAND the crate does not model
prefuse "SELECT A.K FROM BIG A JOIN SMALL B ON A.UNIQ = B.S"
prefuse "SELECT B.S FROM SMALL B JOIN BIG A ON A.UNIQ = B.S"

# ======================================================================
# PHASE 3: the CARDINALITY GRID - 36 cells, and never a wrong plan
# ======================================================================
# Six tables of 0, 1, 5, 50, 500 and 3000 rows, joined every way
# round. For each cell fcopt must either MATCH the engine's plan or
# REFUSE - a wrong plan anywhere fails the gate. This is the property
# that matters for a cost model only partly converted: silence where
# it does not know, exactness where it does.
DBG="$D/fc-optgrid.fdb"
rm -f "$DBG"
{
  echo "CREATE DATABASE '$DBG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  for n in 0 1 5 50 500 3000; do
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
for n in 0 1 5 50 500 3000; do
    "$ISQL" -q -b -user "$U" -pas "$P" "$DBG" >/dev/null 2>&1 <<SQL
SET STATISTICS INDEX IDX_G$n;
COMMIT;
SQL
done
matched=0; refused=0; wrong=0
for o in 0 1 5 50 500 3000; do
  for i in 0 1 5 50 500 3000; do
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
if [ $wrong -eq 0 ] && [ $matched -eq 36 ]; then
    echo "OK   cost grid (FRESH statistics): all 36 cells planned EXACTLY"
elif [ $wrong -eq 0 ]; then
    echo "DIFF cost grid: only $matched of 36 exact ($refused refused) - the cost model regressed"
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
  for n in 0 1 5 50 500 3000; do
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
for o in 0 1 5 50 500 3000; do
  for i in 0 1 5 50 500 3000; do
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
if [ $swrong -eq 0 ]; then
    echo "OK   stale-statistics grid: $smatched exact, $srefused refused, ZERO wrong"
else
    echo "DIFF stale-statistics grid: $swrong cells planned WRONGLY"
    fail=1
fi

exit $fail
