#!/bin/bash
# SUBQUERIES IN WHERE - IN / NOT IN / EXISTS / NOT EXISTS / scalar.
#
# The engine compiles a subquery into a nested blr_rse wrapped in
# blr_any (EXISTS/IN), blr_unique or blr_via (scalar) and evaluates it
# inside the outer stream's loop. fire-crab has no nested-stream
# executor, so it evaluates the inner query up front and folds the
# answer into the outer WHERE: a value set for IN, a SEMI-JOIN set for
# an equality-correlated EXISTS, a literal for a scalar, and a decided
# TRUE/FALSE when the inner query cannot vary per row.
#
# THE DIFFERENTIAL: the same isql runs the same SELECT through the
# engine and through fire-crab and the row sets must be identical.
#
# The teeth are the NULL cases, where the two rewrites must go OPPOSITE
# ways and a plausible implementation gets one of them wrong:
#
#   x NOT IN (SELECT c ...)    a NULL among the values makes every row
#                              UNKNOWN - the result is EMPTY
#   NOT EXISTS (... c = x)     a NULL c matches nothing, so it must be
#                              DROPPED from the semi-join set - the rows
#                              with no partner still come back
#
# Getting these backwards is the classic NOT IN / NOT EXISTS divergence,
# and it is invisible until the inner column actually holds a NULL.
#
#   qa/serve-real-subquery.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4337}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-subq.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, S VARCHAR(10));
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, AID INTEGER, M INTEGER, T VARCHAR(10));
COMMIT;
-- the shapes the subquery evaluator could not reach while it was built
-- around one physical relation
CREATE VIEW VB AS SELECT AID FROM B;
CREATE VIEW VBW AS SELECT AID FROM B WHERE M >= 200;
CREATE VIEW VBR (K) AS SELECT AID FROM B;
CREATE TABLE QE (K INTEGER);
CREATE TABLE QN (K INTEGER);
COMMIT;
INSERT INTO QN VALUES (1);
INSERT INTO QN VALUES (NULL);
COMMIT;
INSERT INTO A VALUES (1, 10, 'x');
INSERT INTO A VALUES (2, 20, 'y');
INSERT INTO A VALUES (3, 30, 'z');
INSERT INTO A VALUES (4, NULL, NULL);
INSERT INTO B VALUES (1, 1, 100, 'x');
INSERT INTO B VALUES (2, 1, 200, 'y');
INSERT INTO B VALUES (3, 2, 300, 'y');
INSERT INTO B VALUES (4, NULL, 400, NULL);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-subq.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0
# run one SELECT both ways and compare the row sets verbatim
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- IN / NOT IN -------------------------------------------------------
same "IN (subquery)"                 "SELECT ID FROM A WHERE ID IN (SELECT AID FROM B)"
same "IN with an inner WHERE"        "SELECT ID FROM A WHERE ID IN (SELECT AID FROM B WHERE M >= 200)"
same "IN over an EMPTY subquery"     "SELECT ID FROM A WHERE ID IN (SELECT AID FROM B WHERE M > 9999)"
same "NOT IN over an EMPTY subquery" "SELECT ID FROM A WHERE ID NOT IN (SELECT AID FROM B WHERE M > 9999)"
same "IN over a TEXT column"         "SELECT ID FROM A WHERE S IN (SELECT T FROM B)"
same "NOT IN over a TEXT column"     "SELECT ID FROM A WHERE S NOT IN (SELECT T FROM B WHERE T IS NOT NULL)"

# --- EXISTS ------------------------------------------------------------
same "correlated EXISTS"             "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID)"
same "correlated NOT EXISTS"         "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID)"
same "correlated EXISTS + inner AND" "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID AND M > 150)"
same "correlation written the other way round" \
                                     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM B WHERE A.ID = B.AID)"
same "uncorrelated EXISTS (true)"    "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM B)"
same "uncorrelated EXISTS (false)"   "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM B WHERE M > 9999)"
same "uncorrelated NOT EXISTS"       "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM B WHERE M > 9999)"

# --- scalar subqueries -------------------------------------------------
same "scalar subquery MIN"           "SELECT ID FROM A WHERE N > (SELECT MIN(M) FROM B)"
same "scalar subquery MAX"           "SELECT ID FROM A WHERE N < (SELECT MAX(M) FROM B)"
same "scalar subquery COUNT"         "SELECT ID FROM A WHERE ID <= (SELECT COUNT(*) FROM B)"

# --- composition with the rest of the WHERE ----------------------------
same "subquery ANDed with a term"    "SELECT ID FROM A WHERE N > 5 AND ID IN (SELECT AID FROM B)"
same "subquery ORed with a term"     "SELECT ID FROM A WHERE N > 25 OR ID IN (SELECT AID FROM B)"
same "subquery + ORDER BY"           "SELECT ID, N FROM A WHERE ID IN (SELECT AID FROM B) ORDER BY ID DESC"
same "COUNT over a subquery filter"  "SELECT COUNT(*) FROM A WHERE ID IN (SELECT AID FROM B)"
same "two subqueries in one WHERE" \
     "SELECT ID FROM A WHERE ID IN (SELECT AID FROM B) AND EXISTS (SELECT 1 FROM B WHERE M > 250)"

# --- THE NULL TEETH: the two rewrites must go OPPOSITE ways ------------
# B.AID holds a NULL. NOT IN must be poisoned by it (empty result);
# NOT EXISTS must NOT be (row 3 and 4 have no partner and come back).
same "NOT IN is poisoned by the inner NULL" \
     "SELECT ID FROM A WHERE ID NOT IN (SELECT AID FROM B)"
same "NOT EXISTS is NOT poisoned by the same NULL" \
     "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID)"

# non-vacuity: those two must actually DISAGREE on this data, or the
# teeth prove nothing
ni=$(printf 'SET HEADING OFF;\nSELECT ID FROM A WHERE ID NOT IN (SELECT AID FROM B);\n' |
     "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
ne=$(printf 'SET HEADING OFF;\nSELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID);\n' |
     "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
if [ "$ni" != "$ne" ]; then
    echo "OK   teeth: NOT IN [$ni] and NOT EXISTS [$ne] really do differ here"
else
    echo "DIFF NOT IN and NOT EXISTS agree - the NULL case is not being exercised"; fail=1
fi


# --- a subquery over something that is NOT a plain relation ------------
# The evaluator resolved a rel id and walked its records, so a VIEW (an
# id with NO records of its own) had to REFUSE rather than answer zero
# rows, and a derived table or a CTE refused with it. An UNCORRELATED
# subquery is a statement, so it is planned as one and materialised -
# through the same branch_rows that now carries a real error.
same "IN over a VIEW"                "SELECT ID FROM A WHERE ID IN (SELECT AID FROM VB) ORDER BY ID"
same "IN over a view with its own WHERE" \
     "SELECT ID FROM A WHERE ID IN (SELECT AID FROM VBW) ORDER BY ID"
same "IN over a view with RENAMED columns" \
     "SELECT ID FROM A WHERE ID IN (SELECT K FROM VBR) ORDER BY ID"
same "NOT IN over a view (inner NULLs decide)" \
     "SELECT ID FROM A WHERE ID NOT IN (SELECT AID FROM VB) ORDER BY ID"
same "EXISTS over a view"            "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VB) ORDER BY ID"
same "NOT EXISTS over an empty-ish view" \
     "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM VBW WHERE AID > 99) ORDER BY ID"
same "IN over a DERIVED table"       "SELECT ID FROM A WHERE ID IN (SELECT X FROM (SELECT AID AS X FROM B) D) ORDER BY ID"
same "IN over a derived table with a WHERE" \
     "SELECT ID FROM A WHERE ID IN (SELECT X FROM (SELECT AID AS X FROM B WHERE M >= 200) D) ORDER BY ID"
same "a scalar subquery over a view" "SELECT ID FROM A WHERE ID = (SELECT MIN(AID) FROM VB) ORDER BY ID"
same "an aggregate over a view"      "SELECT ID FROM A WHERE ID < (SELECT MAX(AID) FROM VB) ORDER BY ID"
same "IN over a UNION"               "SELECT ID FROM A WHERE ID IN (SELECT AID FROM B UNION SELECT ID FROM B) ORDER BY ID"
same "IN over a JOIN"                "SELECT ID FROM A WHERE ID IN (SELECT B.AID FROM B JOIN A ON A.ID = B.AID) ORDER BY ID"
# A CORRELATED subquery over a view. Its WHERE names the OUTER row, so
# it is not a statement on its own - but its SOURCE is, and that was
# the only part the relation path could not walk. The source is planned
# and materialised once, then the correlation splits against its OUTPUT
# columns exactly as it splits against a relation's, which is what
# makes these agree with the engine on NULLs and on the residual WHERE.
same "correlated EXISTS over a view" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VB WHERE VB.AID = A.ID) ORDER BY ID"
same "correlated NOT EXISTS over a view" \
     "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM VB WHERE VB.AID = A.ID) ORDER BY ID"
same "correlated over a view with its own WHERE" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VBW WHERE VBW.AID = A.ID) ORDER BY ID"
same "correlated over a view with RENAMED columns" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VBR WHERE VBR.K = A.ID) ORDER BY ID"
same "correlated with a residual WHERE beside the correlation" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VB WHERE VB.AID = A.ID AND VB.AID > 1) ORDER BY ID"
same "correlated through an ALIAS on the view" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VB V WHERE V.AID = A.ID) ORDER BY ID"
same "the NULL row: a correlated match against a NULL outer value" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM VB WHERE VB.AID = A.N) ORDER BY ID"
# A DERIVED TABLE as the correlated source. Same machinery, different
# source - but it needed a SECOND place to stop resolving columns
# physically: the caller re-derived the correlated OUTER column with
# relation_columns, which a view has (catalog rows) and a derived table
# has not, so a subquery this server had just evaluated correctly was
# refused by the code asking it what it had done. The name travels with
# the rows now.
same "correlated EXISTS over a derived table" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM (SELECT AID AS K FROM B) D WHERE D.K = A.ID) ORDER BY ID"
same "correlated NOT EXISTS over a derived table" \
     "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM (SELECT AID AS K FROM B) D WHERE D.K = A.ID) ORDER BY ID"
same "correlated over a derived table with its own WHERE" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM (SELECT AID AS K FROM B WHERE M >= 200) D WHERE D.K = A.ID) ORDER BY ID"
same "correlated over a derived table with DECLARED column names" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM (SELECT AID FROM B) D (K) WHERE D.K = A.ID) ORDER BY ID"
same "correlated over a derived table, residual conjunct beside it" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM (SELECT AID AS K FROM B) D WHERE D.K = A.ID AND D.K > 1) ORDER BY ID"

# the controls that must not move: the same correlations over a TABLE
same "control: correlated EXISTS over the base table" \
     "SELECT ID FROM A WHERE EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID) ORDER BY ID"
same "control: correlated NOT EXISTS over the base table" \
     "SELECT ID FROM A WHERE NOT EXISTS (SELECT 1 FROM B WHERE B.AID = A.ID) ORDER BY ID"


# --- QUANTIFIED COMPARISONS: <op> ANY | SOME | ALL --------------------
# Measured against the engine before a line was written, because three
# corners are not what the words suggest: `= ANY` is exactly IN and
# `<> ALL` exactly NOT IN (so both go through that path and inherit its
# hash-key marking); an EMPTY set makes ALL vacuously TRUE - including
# for a NULL outer value - and ANY FALSE; and a NULL in the set makes
# ALL unknown while ANY simply ignores it.
same "= ANY is IN"            "SELECT ID FROM A WHERE ID = ANY (SELECT AID FROM B) ORDER BY ID"
same "= SOME is the synonym"  "SELECT ID FROM A WHERE ID = SOME (SELECT AID FROM B) ORDER BY ID"
same "<> ALL is NOT IN"       "SELECT ID FROM A WHERE ID <> ALL (SELECT AID FROM B) ORDER BY ID"
same "= ALL over one value"   "SELECT ID FROM A WHERE ID = ALL (SELECT AID FROM B WHERE M >= 300) ORDER BY ID"
same "= ALL over several"     "SELECT ID FROM A WHERE ID = ALL (SELECT AID FROM B) ORDER BY ID"
same "<> ANY"                 "SELECT ID FROM A WHERE ID <> ANY (SELECT AID FROM B) ORDER BY ID"
same "> ANY beats the least"  "SELECT ID FROM A WHERE ID > ANY (SELECT AID FROM B) ORDER BY ID"
same "> ALL beats them all"   "SELECT ID FROM A WHERE ID > ALL (SELECT AID FROM B) ORDER BY ID"
same ">= ALL"                 "SELECT ID FROM A WHERE ID >= ALL (SELECT AID FROM B) ORDER BY ID"
same "< ANY"                  "SELECT ID FROM A WHERE ID < ANY (SELECT AID FROM B) ORDER BY ID"
same "<= ANY"                 "SELECT ID FROM A WHERE ID <= ANY (SELECT AID FROM B) ORDER BY ID"
# the EMPTY set: ALL is vacuously true OF EVERY ROW, the NULL one too
same "= ALL over an empty set" "SELECT ID FROM A WHERE ID = ALL (SELECT K FROM QE) ORDER BY ID"
same "> ALL over an empty set" "SELECT ID FROM A WHERE ID > ALL (SELECT K FROM QE) ORDER BY ID"
same "= ANY over an empty set" "SELECT ID FROM A WHERE ID = ANY (SELECT K FROM QE) ORDER BY ID"
# a NULL IN THE SET
same "= ANY ignores a NULL"    "SELECT ID FROM A WHERE ID = ANY (SELECT K FROM QN) ORDER BY ID"
same "> ANY ignores a NULL"    "SELECT ID FROM A WHERE ID > ANY (SELECT K FROM QN) ORDER BY ID"
same "= ALL is unknown with a NULL" "SELECT ID FROM A WHERE ID = ALL (SELECT K FROM QN) ORDER BY ID"
same "<> ALL is unknown with a NULL" "SELECT ID FROM A WHERE ID <> ALL (SELECT K FROM QN) ORDER BY ID"
# A NOT IN FRONT is where UNKNOWN and FALSE part company, and this
# token stream can only say FALSE. Over a set with NO NULL the answer
# is exact, so it is an equality; over a NULL-bearing one fire-crab
# REFUSES rather than answer the wrong rows, and that is a boundary.
#
# (B.AID holds a NULL, which is why the clean case has to say so
# explicitly - the first version of this check called B clean, and the
# refusal it got was the design working, not a defect.)
same "NOT over a quantified comparison, a set with no NULL" \
     "SELECT ID FROM A WHERE NOT (ID = ANY (SELECT AID FROM B WHERE AID IS NOT NULL)) ORDER BY ID"
nn=$(printf 'SET HEADING OFF;\nSELECT ID FROM A WHERE NOT (ID = ANY (SELECT AID FROM B)) ORDER BY ID;\n' |
     "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
ne=$(printf 'SET HEADING OFF;\nSELECT ID FROM A WHERE NOT (ID = ANY (SELECT AID FROM B)) ORDER BY ID;\n' |
     "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
case "$nn" in
    *"Dynamic SQL Error"*)
        echo "BOUND NOT over a NULL-bearing quantified set refuses here; engine: [$ne]" ;;
    *) if [ "$nn" = "$ne" ]; then
           echo "OK   NOT over a NULL-bearing quantified set now ANSWERS, and matches"
       else
           echo "DIFF NOT over a NULL-bearing set answered [$nn], engine [$ne]"; fail=1
       fi ;;
esac

# non-vacuity: a subquery filter must not just return every row
all=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM A;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
sub=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM A WHERE ID IN (SELECT AID FROM B);\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
if [ "$all" != "$sub" ]; then
    echo "OK   teeth: the subquery really filters ($sub of $all rows)"
else
    echo "DIFF the subquery filtered nothing"; fail=1
fi

exit $fail
