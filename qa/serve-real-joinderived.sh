#!/bin/bash
# A JOINED DERIVED TABLE ANSWERS ITS OWN COLUMNS - not the base
# relation's fields at the same position.
#
# `SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d
#  ON d.ID = t.ID` must answer J1.G. fire-crab's join side for a
# derived table (and for a view, which is planned the same way) read
# the BASE record by OUTPUT POSITION: `d.S` is output column 1, so it
# fetched base field 1 - `J1.A` - and answered 10, 20, 30 where the
# engine answers g1, g1, g2. Whenever the derived select list is a
# reordering, a subset, a rename or an expression over the base, the
# two orders come apart and the join reads the wrong column.
#
# It is not only a read. The same side feeds a semi-join probe and a
# row source under DML, so `INSERT INTO TQ (ID, A) SELECT t.ID + 10,
# d.S FROM TQ t JOIN (SELECT ID, ID AS S FROM J1) d ON d.ID = t.ID`
# PERSISTED the wrong column's values, and a `DELETE ... WHERE ID IN
# (SELECT ... JOIN <derived> ...)` removed the wrong rows.
#
# Every check is the same script on the engine and on fire-crab.
#
#   qa/serve-real-joinderived.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4066}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-joinderived-crab.fdb"
B="$D/fc-joinderived-engine.fdb"
LOG="/tmp/fc-serve-joinderived-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

cat >"$D/joinderived-$PORT.sql" <<'EOF'
CREATE TABLE J1 (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, G VARCHAR(5), N INTEGER);
CREATE TABLE TQ (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER);
CREATE TABLE SINK (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER);
-- the NOT NULL column is the base's SECOND field, so a derived list
-- naming (ID, V) puts it at OUTPUT position 0 - the two orders come
-- apart in the DESCRIBE exactly as they do in the values
CREATE TABLE K1 (V INTEGER, ID INTEGER NOT NULL PRIMARY KEY);
-- four columns, two of them NOT NULL, so a NESTED derived list can
-- permute them twice and no accidental identity can hide a wrong map
CREATE TABLE K2 (V INTEGER, W INTEGER NOT NULL, Z INTEGER, ID INTEGER NOT NULL PRIMARY KEY);
-- A NAME IS NOT A RELATION. RDB$RELATIONS is keyed by (SCHEMA, NAME),
-- so PUBLIC.T (a TABLE) and S2.T (a VIEW) both live here under the one
-- name T. PUBLIC.T is created FIRST, so T resolves to the TABLE.
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER);
COMMIT;
INSERT INTO J1 VALUES (1, 10, 'g1', 111);
INSERT INTO J1 VALUES (2, 20, 'g1', 222);
INSERT INTO J1 VALUES (3, 30, 'g2', 333);
INSERT INTO J1 VALUES (4, 40, 'g3', 444);
INSERT INTO TQ VALUES (1, 100);
INSERT INTO TQ VALUES (2, 200);
INSERT INTO TQ VALUES (3, 300);
INSERT INTO K1 VALUES (NULL, 1);
INSERT INTO K1 VALUES (7, 2);
INSERT INTO K2 VALUES (NULL, 5, NULL, 1);
INSERT INTO K2 VALUES (8, 6, 9, 2);
INSERT INTO T VALUES (1, 11);
INSERT INTO T VALUES (2, 22);
COMMIT;
CREATE VIEW VS (ID, S) AS SELECT ID, G FROM J1;
CREATE VIEW VN (ID, S, M) AS SELECT ID, G, N FROM J1;
CREATE VIEW VR (S, ID) AS SELECT G, ID FROM J1;
CREATE VIEW VK (ID, V) AS SELECT ID, V FROM K1;
COMMIT;
CREATE SCHEMA S2;
COMMIT;
-- the body resolves in S2, so it has to spell PUBLIC.J1
CREATE VIEW S2.T (ID, A) AS SELECT ID, A FROM PUBLIC.J1;
COMMIT;
EOF
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" -i "$D/joinderived-$PORT.sql" >/dev/null 2>&1 || return 1
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/joinderived-$PORT.sql"' EXIT
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

# ---- 1. the renamed column, which is where the two orders come apart -------------
both "a derived table's renamed column answers its own value, not the base field at that position" \
     "SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID ORDER BY 1;"
both "... and the same through a VIEW, which is planned the same way" \
     "SELECT t.ID, v.S FROM TQ t JOIN VS v ON v.ID = t.ID ORDER BY 1; SELECT t.ID, v.S, v.M FROM TQ t JOIN VN v ON v.ID = t.ID ORDER BY 1;"
both "a view whose column ORDER differs from the base" \
     "SELECT t.ID, v.S FROM TQ t JOIN VR v ON v.ID = t.ID ORDER BY 1;"
both "a derived column that repeats the key, and one that is an expression" \
     "SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, ID AS S FROM J1) d ON d.ID = t.ID ORDER BY 1; SELECT t.ID, d.X FROM TQ t JOIN (SELECT ID, N + 1 AS X FROM J1) d ON d.ID = t.ID ORDER BY 1;"
both "a derived table selecting a SUBSET, and one selecting every column reordered" \
     "SELECT t.ID, d.N FROM TQ t JOIN (SELECT ID, N FROM J1) d ON d.ID = t.ID ORDER BY 1; SELECT t.ID, d.G, d.A FROM TQ t JOIN (SELECT ID, N, G, A FROM J1) d ON d.ID = t.ID ORDER BY 1;"

# ---- 2. the derived side under a predicate, a count and a group ------------------
both "a predicate on the derived column filters on that column" \
     "SELECT COUNT(*) C FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID AND d.S = 'g1'; SELECT t.ID FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID WHERE d.S = 'g2' ORDER BY 1;"
both "GROUP BY the derived column" \
     "SELECT d.S, COUNT(*) C FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID GROUP BY d.S ORDER BY 1;"
both "the derived table's own WHERE still applies" \
     "SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, G AS S FROM J1 WHERE N > 111) d ON d.ID = t.ID ORDER BY 1;"
both "the derived table on the LEFT of the join, and an outer join" \
     "SELECT d.S, t.ID FROM (SELECT ID, G AS S FROM J1) d JOIN TQ t ON d.ID = t.ID ORDER BY 2; SELECT t.ID, d.S FROM TQ t LEFT JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID ORDER BY 1; SELECT d.ID, t.ID FROM (SELECT ID, G AS S FROM J1) d LEFT JOIN TQ t ON d.ID = t.ID ORDER BY 1;"
both "two derived sides, and a derived table over a view" \
     "SELECT a.S, b.M FROM (SELECT ID, G AS S FROM J1) a JOIN (SELECT ID, N AS M FROM J1) b ON a.ID = b.ID ORDER BY 1, 2; SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, S FROM VS) d ON d.ID = t.ID ORDER BY 1;"
both "ORDER BY and a scalar expression over the derived column" \
     "SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID ORDER BY d.S DESC, 1; SELECT t.ID, d.S || '!' AS E FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID ORDER BY 1;"

# ---- 3. the same side under DML - where a wrong read becomes a wrong write -------
both "INSERT ... SELECT over a joined derived table persists the derived column" \
     "INSERT INTO SINK (ID, A) SELECT t.ID + 10, d.S FROM TQ t JOIN (SELECT ID, ID AS S FROM J1) d ON d.ID = t.ID; SELECT ID, A FROM SINK ORDER BY ID; ROLLBACK;"
both "UPDATE whose WHERE joins a derived table touches the right rows" \
     "UPDATE TQ SET A = A + 1 WHERE ID IN (SELECT t.ID FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID WHERE d.S = 'g1') RETURNING ID, A; SELECT ID, A FROM TQ ORDER BY ID; ROLLBACK;"
both "DELETE whose WHERE joins a derived table removes the right rows" \
     "DELETE FROM TQ WHERE ID IN (SELECT t.ID FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID WHERE d.S = 'g2') RETURNING ID; SELECT ID FROM TQ ORDER BY ID; ROLLBACK;"
both "EXISTS over a joined derived table" \
     "SELECT ID FROM TQ x WHERE EXISTS (SELECT 1 FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID WHERE d.S = 'g2' AND t.ID = x.ID) ORDER BY 1;"

# ---- 4. describes ----------------------------------------------------------------
bothd "the derived column's describe names the derived column" \
      "SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID WHERE t.ID = ?;"
bothd "... and through a view" \
      "SELECT t.ID, v.S, v.M FROM TQ t JOIN VN v ON v.ID = t.ID WHERE t.ID = ?;"

# A DERIVED SIDE'S NOT NULL IS ITS OWN COLUMN'S, NOT THE BASE FIELD AT
# THAT POSITION. `K1(V, ID NOT NULL)` read as `(SELECT ID, V FROM K1)`
# puts the NOT NULL column at OUTPUT 0 and the nullable one at OUTPUT 1,
# the base's order exactly reversed. Reading the base's NOT-NULL FIELD
# IDS at an output position announced `d.ID` Nullable and `d.V` NOT NULL
# - both wrong, and the second is not cosmetic: libfbclient IGNORES the
# row's null indicator for a column announced NOT NULL and renders the
# raw buffer, so K1's NULL V came back as 0. The third shape carries an
# expression column, so the side is NOT flattened at all - the mapping is
# the INNER PLAN's, not the flatten's, and holds either way.
bothd "a derived side's NOT NULL follows its own column, not the base field at that position" \
      "SELECT d.ID, d.V FROM TQ t JOIN (SELECT ID, V FROM K1) d ON d.ID = t.ID WHERE t.ID = ?; SELECT v.ID, v.V FROM TQ t JOIN VK v ON v.ID = t.ID WHERE t.ID = ?; SELECT d.ID, d.V FROM TQ t JOIN (SELECT ID, V, 7 AS L FROM K1) d ON d.ID = t.ID WHERE t.ID = ?;"
both "... and the NULL in that column arrives as NULL, not as 0" \
     "SELECT d.ID, d.V FROM TQ t JOIN (SELECT ID, V FROM K1) d ON d.ID = t.ID ORDER BY 1; SELECT v.ID, v.V FROM TQ t JOIN VK v ON v.ID = t.ID ORDER BY 1; SELECT d.ID, d.V FROM TQ t LEFT JOIN (SELECT ID, V FROM K1) d ON d.ID = t.ID ORDER BY 1;"

# A LAYER OVER A LAYER COMPOSES. `(SELECT x.V AS A1, x.ID AS B1 FROM
# (SELECT ID, V FROM K1) x)` has THREE orders in it: K1's fields are
# (V=0, ID=1), the inner derived table's output is (ID, V), the outer
# one's is (A1, B1). Answering `None` for every column of a side whose
# inner plan is not a plain projection - giving up at the first layer -
# announced B1 Nullable, where the engine keeps it NOT NULL because it
# is a plain read of K1.ID two layers down. The K2 shape permutes four
# columns twice so no accidental identity can pass.
bothd "a derived table OVER a derived table announces each column's own nullability" \
      "SELECT d.A1, d.B1 FROM TQ t JOIN (SELECT x.V AS A1, x.ID AS B1 FROM (SELECT ID, V FROM K1) x) d ON d.B1 = t.ID WHERE t.ID = ?; SELECT d.P0, d.P1, d.P2, d.P3 FROM TQ t JOIN (SELECT x.V AS P0, x.W AS P1, x.Z AS P2, x.ID AS P3 FROM (SELECT Z, V, ID, W FROM K2) x) d ON d.P3 = t.ID WHERE t.ID = ?;"
both "... and the nested side answers each column's own value" \
     "SELECT d.A1, d.B1 FROM TQ t JOIN (SELECT x.V AS A1, x.ID AS B1 FROM (SELECT ID, V FROM K1) x) d ON d.B1 = t.ID ORDER BY 2; SELECT d.P0, d.P1, d.P2, d.P3 FROM TQ t JOIN (SELECT x.V AS P0, x.W AS P1, x.Z AS P2, x.ID AS P3 FROM (SELECT Z, V, ID, W FROM K2) x) d ON d.P3 = t.ID ORDER BY 4;"

# A JOINED VIEW WHOSE BODY CANNOT BE RE-PLANNED REFUSES rather than
# scanning a view's empty storage - but the question is about THE
# RELATION THIS SIDE RESOLVES TO, not about any relation sharing its
# name. `PUBLIC.T` is a TABLE and `S2.T` a VIEW; asking "is any relation
# named T a view" refused the TABLE, a case the engine answers - and the
# refusal propagated into DML, so the UPDATE below lost its write.
both "a joined plain TABLE whose name a VIEW in another schema shadows is still a table" \
     "SELECT x.ID, y.A FROM TQ x JOIN PUBLIC.T y ON y.ID = x.ID ORDER BY 1; SELECT x.ID, y.A FROM TQ x JOIN T y ON y.ID = x.ID ORDER BY 1; SELECT COUNT(*) C FROM TQ x JOIN T y ON y.ID = x.ID;"
both "... and a write through that join is not lost" \
     "UPDATE TQ SET A = A + 1 WHERE ID IN (SELECT x.ID FROM TQ x JOIN PUBLIC.T y ON y.ID = x.ID) RETURNING ID, A; SELECT ID, A FROM TQ ORDER BY ID; ROLLBACK;"

# ---- the engine reads fire-crab's own file the same way --------------------------
eng_q="SET LIST ON; SELECT ID, A, G, N FROM J1 ORDER BY ID; SELECT ID, A FROM TQ ORDER BY ID; SELECT COUNT(*) C FROM SINK; SELECT ID, V FROM K1 ORDER BY ID; SELECT V, W, Z, ID FROM K2 ORDER BY ID; SELECT ID, A FROM PUBLIC.T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
