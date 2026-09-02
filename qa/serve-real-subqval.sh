#!/bin/bash
# A SUBQUERY AS A VALUE IN DML - `INSERT ... VALUES (..., (SELECT ...))`
# and `UPDATE ... SET <col> = (SELECT ...)`. The read side has answered
# subqueries for a long time (a select-list item, a WHERE predicate); the
# WRITE side refused every one of them, so the value a statement stores
# could never be looked up. Probed against the live engine and gated
# both ways:
#
#   * an UNCORRELATED subquery is a CONSTANT for the whole statement -
#     answered once and folded in as the literal it computed, so every
#     value shape works over it: the item alone, arithmetic around it,
#     a CAST, a COALESCE, several in one list.
#   * an UPDATE's SET may CORRELATE to the target row (`SET N = (SELECT
#     V FROM P WHERE P.ID = D.ID)`) - one answer per outer key, out of
#     the same lookup table a correlated select-list item builds. An
#     aggregate correlates too, and the absent-key law is the engine's:
#     COUNT answers 0 where every other function answers NULL.
#   * the singleton laws, which are what makes this more than a rewrite:
#     NO ROW answers NULL (not an empty result, and not a skipped
#     assignment), and MORE THAN ONE ROW is the engine's
#     `isc_sing_select_err` - "multiple rows in singleton select",
#     SQLSTATE 21000 - with the statement's writes undone.
#   * every column type the fold has a faithful literal for: INTEGER,
#     NUMERIC, VARCHAR, DATE/TIME/TIMESTAMP and DOUBLE PRECISION (which
#     travels as a cast over its shortest round-tripping text, since
#     `1.5` alone would read back as a scaled numeric).
#
# A clause-splitting bug fell out of it and is pinned here too: the
# statement's own WHERE is the one at PAREN DEPTH ZERO. A SET value's
# subquery carries a WHERE of its own, and taking the first one cut the
# SET list in half.
#
# Boundaries (recorded, all refuse rather than answer): a CORRELATED
# subquery inside a larger expression, a blob-valued subquery, and a
# subquery in an INSERT's value list that names the outer statement
# (there is no outer row to name).
#
#   qa/serve-real-subqval.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4921}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-subqval-crab.fdb"
B="$D/fc-subqval-engine.fdb"
LOG="/tmp/fc-serve-subqval-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
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
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# P is the SOURCE the subqueries read; D is the TARGET they write.
# P.ID pairs with D.ID so a correlation has something to key on, and
# id 3 has NO partner in P - the absent-key row.
mk() { cat <<'SQL'
CREATE TABLE P (ID INTEGER, V INTEGER, T VARCHAR(20), DT DATE, DP DOUBLE PRECISION, NM NUMERIC(9,2));
CREATE TABLE D (ID INTEGER, N INTEGER, S VARCHAR(20), DT DATE, DP DOUBLE PRECISION, NM NUMERIC(9,2));
COMMIT;
INSERT INTO P VALUES (1, 100, 'one', '2020-06-15', 1.5, 12.55);
INSERT INTO P VALUES (2, 200, 'two', '2021-07-16', 2.25, -3.40);
INSERT INTO P VALUES (2, 250, 'dup', '2022-01-01', 3.5, 0.10);
CREATE TABLE P1 (ID INTEGER, T VARCHAR(20), DT DATE);
COMMIT;
INSERT INTO P1 VALUES (1, 'one', '2020-06-15');
INSERT INTO P1 VALUES (2, 'two', '2021-07-16');
INSERT INTO D VALUES (1, 10, 'aa', NULL, NULL, NULL);
INSERT INTO D VALUES (2, 20, 'bb', NULL, NULL, NULL);
INSERT INTO D VALUES (3, 30, 'cc', NULL, NULL, NULL);
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
both "the rows landed the same on both sides" \
  "SELECT ID, V, T, DT, DP, NM FROM P ORDER BY ID, V; SELECT ID, N, S FROM D ORDER BY ID;"

# ---- an UNCORRELATED subquery in INSERT ... VALUES ----------------------
both "a subquery as a whole value item" \
  "INSERT INTO D (ID, N) VALUES (10, (SELECT V FROM P WHERE ID = 1)); COMMIT; SELECT ID, N FROM D WHERE ID = 10;"
both "an aggregate subquery, and one in every position of the list" \
  "INSERT INTO D (ID, N, S) VALUES ((SELECT MAX(ID) FROM P) + 9, (SELECT SUM(V) FROM P), (SELECT T FROM P WHERE ID = 1)); COMMIT; SELECT ID, N, S FROM D WHERE ID = 11;"
both "arithmetic and functions around a subquery" \
  "INSERT INTO D (ID, N, S) VALUES (12, (SELECT V FROM P WHERE ID=1) * 2 + 1, UPPER((SELECT T FROM P WHERE ID=1)) || '!'); COMMIT; SELECT ID, N, S FROM D WHERE ID = 12;"
both "a subquery under a CAST and inside a COALESCE" \
  "INSERT INTO D (ID, N, S) VALUES (13, COALESCE((SELECT V FROM P WHERE ID=9), -1), CAST((SELECT V FROM P WHERE ID=1) AS VARCHAR(10))); COMMIT; SELECT ID, N, S FROM D WHERE ID = 13;"
both "every type the fold spells: a date, a double, a numeric" \
  "INSERT INTO D (ID, DT, DP, NM) VALUES (14, (SELECT DT FROM P WHERE ID=1), (SELECT DP FROM P WHERE ID=1), (SELECT NM FROM P WHERE ID=1)); COMMIT; SELECT ID, DT, DP, NM FROM D WHERE ID = 14;"
both "NO ROW answers NULL, not an empty result" \
  "INSERT INTO D (ID, N, S) VALUES (15, (SELECT V FROM P WHERE ID = 99), (SELECT T FROM P WHERE ID = 99)); COMMIT; SELECT ID, N, S FROM D WHERE ID = 15; SELECT COUNT(*) FROM D WHERE ID = 15 AND N IS NULL;"
both "MORE THAN ONE ROW is the singleton raise, and nothing is stored" \
  "INSERT INTO D (ID, N) VALUES (16, (SELECT V FROM P WHERE ID = 2)); COMMIT; SELECT COUNT(*) FROM D WHERE ID = 16;"

# ---- an UNCORRELATED subquery in UPDATE ... SET -------------------------
both "a subquery as the assigned value" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID = 1) WHERE ID = 1; COMMIT; SELECT ID, N FROM D WHERE ID = 1;"
both "several assignments, one of them a subquery, and a WHERE of its own" \
  "UPDATE D SET N = (SELECT MAX(V) FROM P), S = (SELECT T FROM P WHERE ID = 1) WHERE ID = 2; COMMIT; SELECT ID, N, S FROM D WHERE ID = 2;"
both "arithmetic around it, and the typed columns" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID=1) + 5, DT = (SELECT DT FROM P1 WHERE ID=2), DP = (SELECT DP FROM P WHERE ID=1) WHERE ID = 3; COMMIT; SELECT ID, N, DT, DP FROM D WHERE ID = 3;"
# a statement this server cannot PARSE keeps its syntax refusal, whatever
# its subqueries would have raised: the fold answers them all before the
# SET list is parsed, so a raise must wait for the parse to succeed
refuses_syntax() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*) echo "OK   $1" ;;
        *) echo "DIFF $1"; echo "     [$r]"; fail=1 ;;
    esac
}
refuses_syntax "a raising subquery in an UNPARSEABLE statement keeps the syntax refusal" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID=2) FROM D WHERE ID = 3;"
both "no row answers NULL here too" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID = 99) WHERE ID = 10; COMMIT; SELECT ID, N FROM D WHERE ID = 10;"
both "more than one row raises and the row keeps its value" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID = 2) WHERE ID = 11; COMMIT; SELECT ID, N FROM D WHERE ID = 11;"

# ---- a CORRELATED subquery in UPDATE ... SET ----------------------------
both "correlated to the target row, by column and by aggregate" \
  "UPDATE D SET N = (SELECT SUM(V) FROM P WHERE P.ID = D.ID) WHERE ID <= 3; COMMIT; SELECT ID, N FROM D WHERE ID <= 3 ORDER BY ID;"
both "the absent key: COUNT answers 0 where a value answers NULL" \
  "UPDATE D SET N = (SELECT COUNT(*) FROM P WHERE P.ID = D.ID), S = (SELECT MAX(T) FROM P WHERE P.ID = D.ID) WHERE ID <= 3; COMMIT; SELECT ID, N, S FROM D WHERE ID <= 3 ORDER BY ID;"
both "a correlated bare column" \
  "UPDATE D SET S = (SELECT T FROM P1 WHERE P1.ID = D.ID) WHERE ID <= 3; COMMIT; SELECT ID, S FROM D WHERE ID <= 3 ORDER BY ID;"

# ---- the shapes a subquery may take ------------------------------------
both "the TARGET table read by its own statement, at its starting state" \
  "UPDATE D SET N = (SELECT MAX(N) FROM D) WHERE ID <= 3; COMMIT; SELECT ID, N FROM D WHERE ID <= 3 ORDER BY ID;"
both "the FIRST 1 ... ORDER BY idiom" \
  "UPDATE D SET N = (SELECT FIRST 1 V FROM P ORDER BY V DESC) WHERE ID = 1; COMMIT; SELECT ID, N FROM D WHERE ID = 1;"
both "over a VIEW and over a DERIVED TABLE" \
  "CREATE VIEW PV AS SELECT ID, V FROM P; COMMIT; UPDATE D SET N = (SELECT V FROM PV WHERE ID = 1) WHERE ID = 2; INSERT INTO D (ID, N) VALUES (17, (SELECT MAX(X) FROM (SELECT V AS X FROM P) Z)); COMMIT; SELECT ID, N FROM D WHERE ID IN (2, 17) ORDER BY ID;"
both "a text answer with a quote in it survives the fold" \
  "INSERT INTO P (ID, T) VALUES (7, 'it''s'); COMMIT; INSERT INTO D (ID, S) VALUES (18, (SELECT T FROM P WHERE ID = 7)); COMMIT; SELECT ID, S FROM D WHERE ID = 18;"
both "a MERGE's UPDATE SET takes one too" \
  "MERGE INTO D t USING (SELECT 1 AS K FROM RDB\$DATABASE) s ON t.ID = 18 WHEN MATCHED THEN UPDATE SET N = (SELECT V FROM P WHERE ID = 1); COMMIT; SELECT ID, N FROM D WHERE ID = 18;"
both "one subquery in the SET and another in the WHERE" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID = 1) WHERE ID IN (SELECT ID FROM P WHERE V > 150); COMMIT; SELECT ID, N FROM D WHERE ID <= 3 ORDER BY ID;"
both "a correlated subquery with a residual filter of its own" \
  "UPDATE D SET N = (SELECT SUM(V) FROM P WHERE P.ID = D.ID AND V > 150) WHERE ID <= 3; COMMIT; SELECT ID, N FROM D WHERE ID <= 3 ORDER BY ID;"

# ---- the WHERE that belongs to the statement ---------------------------
both "the statement's own WHERE is the one at depth zero" \
  "UPDATE D SET N = (SELECT V FROM P WHERE ID = 1); COMMIT; SELECT ID, N FROM D ORDER BY ID;"

# ---- a folded subquery is not a plan the cache may keep -----------------
# THE LAW: a plan that READ ROWS at prepare is not a function of (schema,
# text). The same statement text, executed again after its source
# changed, must answer the NEW rows - a kept plan freezes the first
# execution's. Every one of these was measured wrong before the fix, in
# the READ path as much as the write one (a `WHERE ID IN (SELECT ...)`
# counted its first answer for ever).
both "the same text re-executed sees the source's new rows - IN, select list, SET, VALUES" \
  "SELECT COUNT(*) AS C FROM D WHERE ID IN (SELECT ID FROM P1); SELECT (SELECT MAX(V) FROM P) AS M FROM RDB\$DATABASE; INSERT INTO P1 VALUES (3, 'three', NULL); INSERT INTO P (ID, V) VALUES (8, 9999); COMMIT; SELECT COUNT(*) AS C FROM D WHERE ID IN (SELECT ID FROM P1); SELECT (SELECT MAX(V) FROM P) AS M FROM RDB\$DATABASE;"
both "... and the writing halves of the same text" \
  "UPDATE D SET N = (SELECT MAX(V) FROM P) WHERE ID = 1; COMMIT; INSERT INTO P (ID, V) VALUES (9, 20000); COMMIT; UPDATE D SET N = (SELECT MAX(V) FROM P) WHERE ID = 1; COMMIT; SELECT ID, N FROM D WHERE ID = 1;"
both "... a VIEW BODY's subquery too, which the statement's own text does not show" \
  "CREATE VIEW VIN AS SELECT ID, N FROM D WHERE ID IN (SELECT ID FROM P1); COMMIT; SELECT COUNT(*) AS C FROM VIN; INSERT INTO D (ID, N) VALUES (3, 3); COMMIT; SELECT COUNT(*) AS C FROM VIN;"

# ---- the engine reads what fire-crab wrote ------------------------------
eng_q="SET LIST ON; SELECT ID, N, S, DT, DP, NM FROM D ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     [$r]"; fail=1 ;;
    esac
}
# a correlated subquery INSIDE A LARGER EXPRESSION, and a correlated bare
# column whose source has two rows for ANOTHER key: both were recorded
# refusals of the prepare-time lookup table; since 2026-09-02 they are
# evaluated PER TARGET ROW (Expr::CorrSub), so the 21000 for the two-row
# key is raised only when that key is reached - which is when the
# engine raises it
both "a CORRELATED subquery inside a larger expression" \
  "UPDATE D SET N = (SELECT V FROM P WHERE P.ID = D.ID) + 1 WHERE ID = 1 RETURNING ID, N; ROLLBACK;"
both "a correlated bare column whose source has two rows for a key NOT reached" \
  "UPDATE D SET S = (SELECT T FROM P WHERE P.ID = D.ID) WHERE ID = 1 RETURNING ID, S; ROLLBACK;"
both "... and the two-row key, when reached, is the engine's 21000" \
  "UPDATE D SET S = (SELECT T FROM P WHERE P.ID = D.ID) WHERE ID = 2; ROLLBACK;"
refuses "a correlated subquery in an INSERT's value list refuses" \
  "INSERT INTO D (ID, N) VALUES (20, (SELECT V FROM P WHERE P.ID = D.ID));"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
