#!/bin/bash
# CORRELATED SUBQUERIES - a name resolves innermost-first, and an outer
# reference is the OUTER ROW, evaluated per row.
#
# Measured 2026-09-02. fire-crab planned a correlated subquery by
# textual surgery on the inner WHERE - find "the correlation leaf",
# strip qualifiers, bind by NAME - and that model is wrong in both
# directions at once:
#
#   - an UNQUALIFIED name inside the subquery was bound to the OUTER
#     table: `WHERE EXISTS (SELECT 1 FROM D WHERE D.ID = ID)` answered
#     2 rows where the engine (ID is D's, innermost-first) answers all 6;
#   - a SELF-correlation through an alias, `(SELECT MAX(x.A) FROM T x
#     WHERE x.ID < T.ID)`, lost the outer row entirely: NULL for every
#     row in a projection, 0 rows in a WHERE, and `DELETE FROM T t WHERE
#     t.A < (SELECT MAX(x.A) FROM T x WHERE x.ID <> t.ID)` deleted 2 of
#     the 4 rows the engine deletes - a silent wrong write;
#   - `UPDATE T t SET S = (SELECT NM FROM D WHERE D.ID = t.ID)` had `t.`
#     stripped before planning, so `ID` bound to D and the singleton
#     select saw every D row (21000; with a one-row D, a wrong write).
#
# Everything else in the family - CASE / COALESCE / ORDER BY / HAVING /
# JOIN ON / RETURNING / IN / ANY / ALL / SOME / two levels deep / over a
# view or a derived table - refused. Every check below is the same
# script on the engine and on fire-crab; the 700-row BIG ranking crosses
# the 500-row fetch boundary and asserts a specific row, not a count.
#
#   qa/serve-real-corrsub.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4060}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-corrsub-crab.fdb"
B="$D/fc-corrsub-engine.fdb"
LOG="/tmp/fc-serve-corrsub-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

cat >"$D/corrsub-$PORT.sql" <<'EOF'
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(10));
CREATE TABLE D (ID INTEGER NOT NULL PRIMARY KEY, NM VARCHAR(10), A INTEGER);
CREATE TABLE E (ID INTEGER, TID INTEGER, V INTEGER);
CREATE TABLE BIG (ID INTEGER NOT NULL PRIMARY KEY, G INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10, 'x');
INSERT INTO T VALUES (2, 20, 'y');
INSERT INTO T VALUES (3, 30, 'z');
INSERT INTO T VALUES (4, NULL, NULL);
INSERT INTO T VALUES (5, 50, 'w');
INSERT INTO T VALUES (6, 60, 'v');
INSERT INTO D VALUES (1, 'one', 111);
INSERT INTO D VALUES (2, 'two', 222);
INSERT INTO D VALUES (7, 'seven', 777);
INSERT INTO E VALUES (1, 1, 5);
INSERT INTO E VALUES (2, 1, 6);
INSERT INTO E VALUES (3, 2, 7);
INSERT INTO E VALUES (4, 5, 8);
COMMIT;
CREATE VIEW VT AS SELECT ID, A FROM T WHERE A > 15;
COMMIT;
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 1; BEGIN WHILE (I <= 700) DO BEGIN INSERT INTO BIG VALUES (:I, MOD(:I, 7)); I = I + 1; END END^
SET TERM ;^
COMMIT;
EOF
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" -i "$D/corrsub-$PORT.sql" >/dev/null 2>&1 || return 1
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/corrsub-$PORT.sql"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON; SET PLANONLY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a -E 'sqltype|name:|SQLSTATE' | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON; SET PLANONLY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a -E 'sqltype|name:|SQLSTATE' | norm)
    check "$1" "$c" "$e"
}

# ---- 1. a scalar subquery in the projection ---------------------------------
both "a correlated scalar: the outer table's column by name and by alias" \
     "SELECT ID, (SELECT NM FROM D WHERE D.ID = T.ID) NM FROM T ORDER BY ID; SELECT t.ID, (SELECT D.NM FROM D WHERE D.ID = t.ID) NM FROM T t ORDER BY t.ID;"
both "a SELF-correlation through an alias: the ranking idiom" \
     "SELECT ID, (SELECT MAX(x.A) FROM T x WHERE x.ID < T.ID) MX FROM T ORDER BY ID; SELECT ID, (SELECT COUNT(*) FROM T x WHERE x.A > T.A) HIGHER FROM T ORDER BY ID;"
both "an aggregate over another table, correlated by an unqualified inner column" \
     "SELECT ID, (SELECT COUNT(*) FROM E WHERE E.TID = T.ID) CNT FROM T ORDER BY ID; SELECT ID, (SELECT SUM(V) FROM E WHERE TID = T.ID) SM FROM T ORDER BY ID;"
both "two correlated predicates in one inner WHERE" \
     "SELECT ID, (SELECT NM FROM D WHERE D.ID = T.ID AND D.A > T.A) NM FROM T ORDER BY ID;"
both "two levels deep: the middle scope and the outer scope both reachable" \
     "SELECT ID, (SELECT (SELECT MAX(V) FROM E WHERE E.TID = D.ID) FROM D WHERE D.ID = T.ID) DEEP FROM T ORDER BY ID;"
both "a correlated subquery inside CASE and COALESCE" \
     "SELECT ID, CASE WHEN (SELECT COUNT(*) FROM E WHERE E.TID = T.ID) > 1 THEN 'many' ELSE 'few' END K FROM T ORDER BY ID; SELECT ID, COALESCE((SELECT MAX(V) FROM E WHERE E.TID = T.ID), -1) MV FROM T ORDER BY ID;"

# ---- 2. the subquery in WHERE -----------------------------------------------
both "EXISTS: an UNQUALIFIED inner name is the INNER table's (every outer row qualifies)" \
     "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM D WHERE D.ID = ID) ORDER BY ID;"
both "EXISTS / NOT EXISTS with a qualified outer reference" \
     "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM D WHERE D.ID = T.ID) ORDER BY ID; SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM E WHERE E.TID = T.ID) ORDER BY ID; SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM E WHERE E.TID = T.ID AND E.V > 6) ORDER BY ID;"
both "a scalar comparison against a self-correlated aggregate" \
     "SELECT ID FROM T WHERE A > (SELECT MAX(x.A) FROM T x WHERE x.ID < T.ID) ORDER BY ID; SELECT ID FROM T WHERE A = (SELECT MAX(A) FROM T x WHERE x.S < T.S);"
both "IN / ANY / SOME / ALL over a correlated inner WHERE" \
     "SELECT ID FROM T WHERE ID IN (SELECT E.TID FROM E WHERE E.V > T.A - 50) ORDER BY ID; SELECT ID FROM T WHERE ID = ANY (SELECT TID FROM E WHERE E.V > T.A - 45) ORDER BY ID; SELECT ID FROM T WHERE A < SOME (SELECT V * 10 FROM E WHERE E.TID = T.ID) ORDER BY ID; SELECT ID FROM T WHERE A > ALL (SELECT V FROM E WHERE E.TID = T.ID) ORDER BY ID;"

# ---- 3. other expression contexts -------------------------------------------
both "ORDER BY a correlated subquery" \
     "SELECT ID FROM T ORDER BY (SELECT COUNT(*) FROM E WHERE E.TID = T.ID) DESC, ID;"
both "HAVING against a correlated subquery over the group key" \
     "SELECT TID, COUNT(*) C FROM E GROUP BY TID HAVING COUNT(*) > (SELECT COUNT(*) FROM D WHERE D.ID = E.TID) ORDER BY TID;"
both "a correlated subquery in a JOIN's ON" \
     "SELECT T.ID, D.NM FROM T JOIN D ON D.ID = T.ID AND D.A > (SELECT MIN(V) FROM E WHERE E.TID = T.ID) ORDER BY T.ID;"
both "correlation over a VIEW and over a derived table" \
     "SELECT ID, (SELECT COUNT(*) FROM VT x WHERE x.A > VT.A) H FROM VT ORDER BY ID; SELECT q.ID, (SELECT COUNT(*) FROM E WHERE E.TID = q.ID) C FROM (SELECT ID FROM T) q ORDER BY q.ID;"

# ---- 4. DML --------------------------------------------------------------------
both "UPDATE SET from a self-correlated aggregate" \
     "UPDATE T SET A = (SELECT MAX(x.A) FROM T x WHERE x.ID < T.ID) WHERE ID = 3 RETURNING ID, A; SELECT ID, A FROM T WHERE ID = 3; ROLLBACK;"
both "UPDATE with a statement alias inside the SET's subquery" \
     "UPDATE T t SET S = (SELECT NM FROM D WHERE D.ID = t.ID) WHERE t.ID = 1 RETURNING t.ID, t.S; UPDATE T SET S = (SELECT NM FROM D WHERE D.ID = T.ID) WHERE ID = 2 RETURNING ID, S; SELECT ID, S FROM T ORDER BY ID; ROLLBACK;"
both "UPDATE SET where the inner WHERE names an unqualified column (the INNER table's)" \
     "UPDATE T SET A = (SELECT SUM(V) FROM E WHERE E.TID = ID) WHERE ID = 5 RETURNING ID, A; UPDATE T SET A = (SELECT SUM(V) FROM E WHERE TID = T.ID) WHERE ID = 1 RETURNING ID, A; ROLLBACK;"
both "DELETE by a self-correlated comparison through the statement alias" \
     "DELETE FROM T t WHERE t.A < (SELECT MAX(x.A) FROM T x WHERE x.ID <> t.ID) RETURNING t.ID; SELECT COUNT(*) C FROM T; ROLLBACK;"
both "DELETE where EXISTS binds the unqualified name to the inner table" \
     "DELETE FROM T WHERE EXISTS (SELECT 1 FROM D WHERE D.ID = ID) RETURNING ID; SELECT COUNT(*) C FROM T; ROLLBACK;"
both "UPDATE ... WHERE IN / scalar with a correlated inner WHERE" \
     "UPDATE T SET A = A + 1 WHERE ID IN (SELECT TID FROM E WHERE E.V > T.A - 50) RETURNING ID, A; ROLLBACK; UPDATE T SET A = 0 WHERE A > (SELECT AVG(x.A) FROM T x WHERE x.ID <> T.ID) RETURNING ID; ROLLBACK;"
both "RETURNING a correlated subquery" \
     "UPDATE T SET A = 1 WHERE ID = 1 RETURNING ID, (SELECT NM FROM D WHERE D.ID = T.ID); ROLLBACK;"

# ---- 5. past the fetch boundary ------------------------------------------------
both "700 rows: a within-group rank and a previous-id lookup, specific rows asserted" \
     "SELECT ID, (SELECT COUNT(*) FROM BIG b WHERE b.G = BIG.G AND b.ID < BIG.ID) RANKG FROM BIG WHERE ID IN (1, 8, 700); SELECT COUNT(*) C FROM BIG WHERE (SELECT COUNT(*) FROM BIG b WHERE b.G = BIG.G AND b.ID < BIG.ID) = 0; SELECT COUNT(*) C FROM BIG WHERE (SELECT MAX(x.ID) FROM BIG x WHERE x.G = BIG.G AND x.ID < BIG.ID) IS NULL;"
e=$(printf 'SET HEADING OFF;\nSELECT ID, (SELECT MAX(x.ID) FROM BIG x WHERE x.G = BIG.G AND x.ID < BIG.ID) P FROM BIG ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | awk '$1==699{n++; v=$2} END{print n"|"v}')
c=$(printf 'SET HEADING OFF;\nSELECT ID, (SELECT MAX(x.ID) FROM BIG x WHERE x.G = BIG.G AND x.ID < BIG.ID) P FROM BIG ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | awk '$1==699{n++; v=$2} END{print n"|"v}')
check "... and row 699 of the 700-row correlated result is delivered exactly once, with its previous id" "$c" "$e"

# ---- 6. describes ----------------------------------------------------------------
bothd "a correlated scalar column is typed by its inner expression" \
      "SELECT ID, (SELECT A FROM D WHERE D.ID = T.ID) DA, (SELECT COUNT(*) FROM E WHERE E.TID = T.ID) C, (SELECT NM FROM D WHERE D.ID = T.ID) FROM T WHERE ID = ?;"
bothd "a self-correlated MAX describes as the column's type, not text" \
      "SELECT ID, (SELECT MAX(x.A) FROM T x WHERE x.ID < T.ID) MX FROM T WHERE ID = ?;"

# ---- the engine reads fire-crab's own file the same way ------------------------
eng_q="SET LIST ON; SELECT ID, A, S FROM T ORDER BY ID; SELECT COUNT(*) C FROM BIG;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
