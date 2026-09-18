#!/bin/bash
# `WITH RECURSIVE` - a CTE that is a FIXPOINT rather than a substitution,
# compared statement by statement against the real engine over two
# identical databases.
#
# Every other CTE in this server is answered by REWRITING: the body is
# spliced in where the name stood and the statement is re-planned. A
# recursive CTE cannot be, because the name it must resolve is ITS OWN -
# there is no text to substitute. So it is evaluated the way the engine
# evaluates it:
#
#   the SEED runs once and its rows are the first level;
#   the RECURSIVE BRANCH is then evaluated AGAINST THE LAST LEVEL'S ROWS,
#   over and over, until a round produces nothing;
#   the accumulated rows are the CTE.
#
# What makes that expressible at all is the row-source tree: a level's
# rows are a MATERIALISED LEAF, and since R5a a leaf can be a SIDE OF A
# JOIN. That is the whole of the hierarchy walk - `FROM ORG O JOIN C ON
# O.PARENT = C.ID` goes to the ORDINARY join planner with `C` bound to
# the rows in hand, and nothing about the join changes.
#
# The checks the engine REJECTS matter as much as the ones it answers,
# because each is a place this could answer instead of refusing:
#
#   two self-references     a fixpoint over a product; binding both
#                           sides to the same rows would have answered
#   ORDER BY in a branch    a union branch carries no sort of its own
#   no termination          bounded at 1024 levels, as the engine bounds
#                           its own recursion, so it raises rather than
#                           runs forever
#
# And `WITH RECURSIVE` on a body that never names itself is an ORDINARY
# CTE - the keyword is a declaration, not a fact - so it must still take
# the ordinary path and answer.
#
#   qa/serve-real-recursive.sh [port]
#
# Needs the real engine on 3050 (FC_REAL_PORT overrides) and node with
# node-firebird.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4553}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-rec-crab.fdb"
B="$D/fc-rec-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE ORG (ID INTEGER, PARENT INTEGER, NAME VARCHAR(6));
CREATE TABLE T (ID INTEGER, N INTEGER, V VARCHAR(10));
-- THE WALK-ORDER TABLES. ORG is left exactly as it was: existing cells
-- select from it, so an extra row would move their result sets.
--   TREE  two roots, uneven depth, siblings inserted OUT of id order (9
--         before 8) and ONE ORPHAN (99 under a parent that does not
--         exist) which must never appear in a walk;
--   DIA   a diamond - 4 is reachable under both 2 and 3, so a depth-first
--         walk emits it TWICE, once per path;
--   DUP   two identical rows, which UNION ALL keeps;
--   CYC   a cycle reachable from the root: the engine does not detect it,
--         it recurses until the depth bound and raises 54001;
--   CH    a 1025-deep chain. Seeded at the root it is 1025 deep and
--         raises; seeded at ID=2 it is 1024 and answers; at ID=3, 1023.
--         One table, all three sides of the bound.
CREATE TABLE TREE (ID INTEGER, PARENT INTEGER);
CREATE TABLE DIA  (ID INTEGER, PARENT INTEGER);
CREATE TABLE DUP  (ID INTEGER, PARENT INTEGER);
CREATE TABLE CYC  (ID INTEGER, PARENT INTEGER);
CREATE TABLE CH   (ID INTEGER, PARENT INTEGER);
COMMIT;
INSERT INTO ORG VALUES (1, NULL, 'root');
INSERT INTO ORG VALUES (2, 1, 'a');
INSERT INTO ORG VALUES (3, 1, 'b');
INSERT INTO ORG VALUES (4, 2, 'aa');
INSERT INTO ORG VALUES (5, 4, 'aaa');
INSERT INTO ORG VALUES (9, 9, 'loop');
INSERT INTO T VALUES (1, 10, 'a');
INSERT INTO T VALUES (2, 20, 'b');
INSERT INTO T VALUES (3, 30, 'c');
INSERT INTO T VALUES (4, 40, 'd');
INSERT INTO T VALUES (5, 50, NULL);
INSERT INTO TREE VALUES (1, NULL);
INSERT INTO TREE VALUES (2, 1);
INSERT INTO TREE VALUES (3, 1);
INSERT INTO TREE VALUES (4, 2);
INSERT INTO TREE VALUES (5, 3);
INSERT INTO TREE VALUES (6, 4);
INSERT INTO TREE VALUES (7, NULL);
INSERT INTO TREE VALUES (9, 7);
INSERT INTO TREE VALUES (8, 7);
INSERT INTO TREE VALUES (10, 9);
INSERT INTO TREE VALUES (99, 77);
-- SOMETHING TO JOIN THE WALK AGAINST. This gate owned TREE but nothing to
-- join it to, which is why the join-driver divergence survived the
-- depth-first chunk: a walk on its own can never show WHO DRIVES. JM is
-- stored OUT of order (50, 10, 20, 40) with DUPLICATE keys (10 and 20 both
-- name TREE 1) and a row matching NOTHING (30 -> 99), because a 1:1 fixture
-- hides the pairing and an ascending one hides the order - the two blind
-- spots that hid this law and the RIGHT-join one before it.
CREATE TABLE JM (MID INTEGER, ID INTEGER);
CREATE TABLE JN (NID INTEGER, ID INTEGER);
-- JK carries a PRIMARY KEY on the join column: the engine drives the CTE
-- when an index serves that column, and this server already agrees there.
CREATE TABLE JK (ID INTEGER NOT NULL PRIMARY KEY, KTAG VARCHAR(3));
COMMIT;
INSERT INTO JM VALUES (50, 9);
INSERT INTO JM VALUES (10, 1);
INSERT INTO JM VALUES (30, 99);
INSERT INTO JM VALUES (20, 1);
INSERT INTO JM VALUES (40, 2);
INSERT INTO JN VALUES (700, 2);
INSERT INTO JN VALUES (500, 1);
INSERT INTO JN VALUES (900, 9);
INSERT INTO JK VALUES (9, 'k9');
INSERT INTO JK VALUES (1, 'k1');
INSERT INTO JK VALUES (2, 'k2');
INSERT INTO DIA VALUES (1, NULL);
INSERT INTO DIA VALUES (2, 1);
INSERT INTO DIA VALUES (3, 1);
INSERT INTO DIA VALUES (4, 2);
INSERT INTO DIA VALUES (5, 3);
INSERT INTO DIA VALUES (4, 3);
INSERT INTO DUP VALUES (1, NULL);
INSERT INTO DUP VALUES (2, 1);
INSERT INTO DUP VALUES (2, 1);
INSERT INTO CYC VALUES (1, NULL);
INSERT INTO CYC VALUES (2, 1);
INSERT INTO CYC VALUES (3, 2);
INSERT INTO CYC VALUES (1, 3);
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER; BEGIN
  I = 1;
  INSERT INTO CH VALUES (1, NULL);
  WHILE (I < 1025) DO BEGIN INSERT INTO CH VALUES (:I + 1, :I); I = I + 1; END
END^
SET TERM ; ^
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-recursive.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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

query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
# A RECORDED DIVERGENCE, self-expiring: the two servers must still DISAGREE.
# It goes red if they start AGREEING - which is the signal to promote the
# cell back to `both` - and red if EITHER side fails to answer, so a
# CONN_ERR or an ERR can never be scored as a difference. That guard is
# two-sided on purpose: a one-sided one let this server's own refusal count
# as a divergence while measuring nothing at all.
differs() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    case "$a" in CONN_ERR|ERR*|"") echo "DIFF $1 [VACUOUS: fcwire did not answer: $a]"; fail=1; return ;; esac
    case "$b" in CONN_ERR|ERR*|"") echo "DIFF $1 [VACUOUS: the engine did not answer: $b]"; fail=1; return ;; esac
    if [ "$a" = "$b" ]; then
        echo "DIFF $1 NOW AGREES - the driver order is fixed; promote this cell to both"
        echo "     both: $a"
        fail=1
    else
        echo "OK   recorded divergence: $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
    fi
}

refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refused: $1" ;;
        *) echo "DIFF $1 answered: [$r]"; fail=1 ;;
    esac
}


# --- 0. the controls: the shapes recursion is built out of -------------
both "a NON-recursive CTE still works" \
     "WITH C AS (SELECT ID FROM T WHERE ID < 3) SELECT ID FROM C ORDER BY ID"
both "a plain UNION ALL still works" \
     "SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT ID FROM T WHERE ID = 2"
both "WITH RECURSIVE on a body that never names itself" \
     "WITH RECURSIVE C AS (SELECT ID FROM T WHERE ID < 3) SELECT ID FROM C ORDER BY ID"

# --- 1. the counter: the smallest fixpoint there is --------------------
both "the classic counter" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 5) SELECT N FROM C ORDER BY N"
both "a step of two" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+2 FROM C WHERE N < 9) SELECT N FROM C ORDER BY N DESC"
both "one level only - the branch is false at once" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 0) SELECT N FROM C ORDER BY N"
both "the seed is a TABLE, not RDB\$DATABASE" \
     "WITH RECURSIVE C AS (SELECT ID AS N FROM T WHERE ID = 1
        UNION ALL SELECT N+1 FROM C WHERE N < 4) SELECT * FROM C ORDER BY N"
both "the seed is an AGGREGATE" \
     "WITH RECURSIVE C AS (SELECT MIN(ID) AS N FROM T
        UNION ALL SELECT N+1 FROM C WHERE N < 5) SELECT N FROM C ORDER BY N"
both "the seed is MANY rows" \
     "WITH RECURSIVE C AS (SELECT ID AS N, V AS W FROM T
        UNION ALL SELECT N+10, W FROM C WHERE N < 6) SELECT N, W FROM C ORDER BY N"

# --- 2. what the final query may do with the rows ----------------------
both "a WHERE over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 5) SELECT N FROM C WHERE N > 3 ORDER BY N"
both "an EXPRESSION over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 6) SELECT N, N*10 AS M FROM C WHERE N > 3 ORDER BY N"
both "a CASE over the CTE" \
     "WITH RECURSIVE C AS (SELECT 0 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 3)
      SELECT CASE WHEN N > 1 THEN 'hi' ELSE 'lo' END AS L FROM C ORDER BY N"
both "FIRST over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 20) SELECT FIRST 3 N FROM C ORDER BY N"
both "SKIP over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 5) SELECT SKIP 1 N FROM C ORDER BY N"
both "FIRST with a DESCENDING sort" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 4) SELECT FIRST 2 N FROM C ORDER BY N DESC"
both "DISTINCT over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 3) SELECT DISTINCT N FROM C ORDER BY N"
both "a text column carried through the recursion" \
     "WITH RECURSIVE C AS (SELECT 1 AS N, 'x' AS S FROM RDB\$DATABASE
        UNION ALL SELECT N+1, S FROM C WHERE N < 3) SELECT N, S FROM C ORDER BY N"

# --- 3. the CTE NAMES ITS OWN COLUMNS ----------------------------------
# the seed supplies the values; `C(X)` supplies the names
both "one declared column name" \
     "WITH RECURSIVE C(X) AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT X+1 FROM C WHERE X < 3) SELECT X FROM C ORDER BY X"
both "two declared column names" \
     "WITH RECURSIVE C(X,Y) AS (SELECT 1, 'a' FROM RDB\$DATABASE
        UNION ALL SELECT X+1, Y FROM C WHERE X < 3) SELECT X, Y FROM C ORDER BY X"

# --- 4. AGGREGATING the accumulated rows -------------------------------
both "COUNT over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 4) SELECT COUNT(*) AS K FROM C"
both "every aggregate at once" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 4)
      SELECT SUM(N) AS S, MIN(N) AS L, MAX(N) AS H, AVG(N) AS A FROM C"
both "COUNT with a WHERE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 4) SELECT COUNT(*) AS K FROM C WHERE N > 2"
both "GROUP BY an expression over the CTE" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 4)
      SELECT MOD(N,2) AS M, COUNT(*) AS K FROM C GROUP BY MOD(N,2) ORDER BY M"
both "GROUP BY with a HAVING" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 4)
      SELECT N, COUNT(*) AS K FROM C GROUP BY N HAVING COUNT(*) > 0 ORDER BY N"

# --- 5. the HIERARCHY WALK - what a recursive CTE is usually FOR -------
# the recursive branch JOINS the table to the rows so far; the join
# planner does it, with the CTE bound as a side (R5a)
both "the walk, with a level counter" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, NAME, 0 AS LVL FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT, O.NAME, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT ID, LVL FROM C ORDER BY ID"
both "the walk's names in level order" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, NAME, 0 AS LVL FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT, O.NAME, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT NAME, LVL FROM C ORDER BY LVL, NAME"
both "how many at each level" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, NAME, 0 AS LVL FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT, O.NAME, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT LVL, COUNT(*) AS K FROM C GROUP BY LVL ORDER BY LVL"
both "the whole subtree counted" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, NAME, 0 AS LVL FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT, O.NAME, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT COUNT(*) AS K FROM C"
both "the walk from a NON-root seed" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, 0 AS LVL FROM ORG WHERE ID = 2
        UNION ALL SELECT O.ID, O.PARENT, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT ID, LVL FROM C ORDER BY ID"
both "a seed that matches NOTHING" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, 0 AS LVL FROM ORG WHERE ID = 99
        UNION ALL SELECT O.ID, O.PARENT, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT COUNT(*) AS K FROM C"
both "the WHERE in the recursive branch bounds the depth" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, 0 AS LVL FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT, C.LVL+1 FROM ORG O JOIN C ON O.PARENT = C.ID
        WHERE C.LVL < 1)
      SELECT ID, LVL FROM C ORDER BY ID"

# --- 6. the CTE in the FINAL query's own JOIN --------------------------
both "the CTE joined to a real table" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 3)
      SELECT C.N, T.V FROM C JOIN T ON T.ID = C.N ORDER BY C.N"
both "the CTE used TWICE in the final query" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C WHERE N < 3)
      SELECT A.N, B.N AS M FROM C A JOIN C B ON A.N = B.N ORDER BY A.N"

# --- 7. what the ENGINE rejects, which this must reject too -----------
# each of these is a shape that could have been ANSWERED instead
refuses "a recursion that never terminates" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C) SELECT N FROM C"
refuses "a row that is its own parent - the same non-termination" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT FROM ORG WHERE ID = 9
        UNION ALL SELECT O.ID, O.PARENT FROM ORG O JOIN C ON O.PARENT = C.ID)
      SELECT COUNT(*) FROM C"
refuses "TWO self-references in the recursive branch" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT C1.N+1 FROM C C1 JOIN C C2 ON C1.N = C2.N WHERE C1.N < 3)
      SELECT N FROM C"
refuses "ORDER BY inside the seed" \
     "WITH RECURSIVE C AS (SELECT ID AS N FROM T WHERE ID = 1 ORDER BY ID
        UNION ALL SELECT N+1 FROM C WHERE N < 3) SELECT N FROM C ORDER BY N"
refuses "UNION rather than UNION ALL" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION SELECT N+1 FROM C WHERE N < 3) SELECT N FROM C"
refuses "a LEFT JOIN to the recursive reference" \
     "WITH RECURSIVE C AS (SELECT ID, PARENT, 0 AS LVL FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT, C.LVL+1 FROM ORG O LEFT JOIN C ON O.PARENT = C.ID)
      SELECT ID, LVL FROM C ORDER BY ID"

# --- THE WALK ORDER: the engine goes DEPTH-FIRST, PRE-ORDER ------------
# Every cell above pins its order with ORDER BY or walks a CHAIN, where a
# depth-first and a breadth-first walk are the same sequence - which is why
# a level-at-a-time fixpoint sat here for so long looking correct. It is
# not: over a TREE the engine descends each branch to the bottom before
# taking the next sibling, and a queue answers by level.
#
# Measured against the engine, with no ORDER BY anywhere:
#   ORG        1,2,4,5,3            (a queue gives 1,2,3,4,5)
#   TREE       1,2,4,6,3,5,7,9,10,8 (a queue gives 1,7,2,3,9,8,4,5,10,6)
#   the LEVEL  0,1,2,3,1,2,0,1,2,1  (a queue gives 0,0,1,1,1,1,2,2,2,3)
# Siblings and roots follow RECORD order, not id order - TREE's 9 is
# inserted before its 8 and comes back first - and the orphan 99 never
# enters any walk.
ORGW="WITH RECURSIVE C AS (SELECT ID, PARENT FROM ORG WHERE PARENT IS NULL
        UNION ALL SELECT O.ID, O.PARENT FROM ORG O JOIN C ON O.PARENT = C.ID)"
TRW="WITH RECURSIVE C AS (SELECT ID, PARENT, 0 AS LVL FROM TREE WHERE PARENT IS NULL
        UNION ALL SELECT T2.ID, T2.PARENT, C.LVL+1 FROM TREE T2 JOIN C ON T2.PARENT = C.ID)"
both "a bare ORG walk is depth-first"        "$ORGW SELECT ID FROM C"
both "a two-root tree, uneven depth"         "$TRW SELECT ID FROM C"
both "...and the LEVEL it reports"           "$TRW SELECT LVL FROM C"
both "one root only"                         "WITH RECURSIVE C AS (SELECT ID, PARENT FROM TREE WHERE ID = 1
        UNION ALL SELECT T2.ID, T2.PARENT FROM TREE T2 JOIN C ON T2.PARENT = C.ID) SELECT ID FROM C"
both "the other root, siblings 9 then 8"     "WITH RECURSIVE C AS (SELECT ID, PARENT FROM TREE WHERE ID = 7
        UNION ALL SELECT T2.ID, T2.PARENT FROM TREE T2 JOIN C ON T2.PARENT = C.ID) SELECT ID FROM C"
both "a WHERE over the walk keeps the order"  "$TRW SELECT ID FROM C WHERE LVL > 0"

# --- WHO DRIVES when the walk is JOINED to something ---------------------
# RECORDED, NOT FIXED - and the cells below say which is which.
#
# THE LAW, measured: the engine DEMOTES a recursive CTE out of the driving
# position and drives the other stream, so rows come back grouped by THAT
# side's rows in ITS storage order. Over JM stored 50,10,30,20,40 the engine
# answers `50/9 10/1 20/1 40/2`; this server answers the WALK's order. It is
# NOT order-only - a FIRST/SKIP slice then takes a DIFFERENT SET OF ROWS -
# and it holds with a table, a derived table and a view opposite the CTE
# alike, and only when the CTE is written FIRST.
#
# THE ENGINE ONLY DOES THAT FOR A PLAIN JOIN. It drives the CTE instead -
# and this server already agrees - when a conjunct in the WHERE or the ON
# names one of the two streams, or when an index serves the join column.
# Those are the `both` cells further down, and they are the reason a blanket
# "group by the other side" would be a NEW wrong answer rather than a fix.
#
# WHY IT IS RECORDED. The ordering cannot live in [join_step], where the
# RIGHT-join law lives: for an INNER equi-join every one of its call sites
# passes a ONE-ROW accumulated side (`rows_materialised` takes its whole-acc
# early return only for non-LEFT/INNER kinds; `JoinCursor::fold` expands one
# base row at a time), so a sort there reorders within a single row's slice
# and measures as doing NOTHING - which is exactly what a first attempt did.
# Ordering it correctly means carrying the other side's row index out to the
# three concatenation points - the streaming arm, the materialising loop and
# the cursor - i.e. changing a function called from twelve sites on the
# hottest path in the server, for a LOW-tier bullet. Not attempted on this
# evidence; the `differs` cells go red the day someone does it.
differs "walk JOIN table: who drives"        "$TRW SELECT M.MID FROM C R JOIN JM M ON M.ID = R.ID"
differs "walk JOIN table: the pairing"       "$TRW SELECT M.MID, R.ID FROM C R JOIN JM M ON M.ID = R.ID"
differs "FIRST 3 over it (a rowset, not an order)" "$TRW SELECT FIRST 3 M.MID FROM C R JOIN JM M ON M.ID = R.ID"
differs "SKIP 2 over it"                     "$TRW SELECT SKIP 2 M.MID FROM C R JOIN JM M ON M.ID = R.ID"
differs "a DERIVED table opposite the walk"  "$TRW SELECT Z.MID FROM C R JOIN (SELECT MID, ID FROM JM) Z ON Z.ID = R.ID"
differs "a comma join"                       "$TRW SELECT M.MID FROM C R, JM M WHERE M.ID = R.ID"
differs "a three-way chain"                  "$TRW SELECT M.MID, N.NID FROM C R JOIN JM M ON M.ID = R.ID JOIN JN N ON N.ID = R.ID"
# ...and the shapes where the engine drives the CTE INSTEAD, which this
# server already matched and must keep matching. Each is one condition of
# the guard: a conjunct naming a stream (in the WHERE or in the ON), and an
# index serving the join column.
both "WHERE on the table (engine drives CTE)"  "$TRW SELECT M.MID FROM C R JOIN JM M ON M.ID = R.ID WHERE M.MID > 15"
both "WHERE on the walk (engine drives CTE)"   "$TRW SELECT M.MID FROM C R JOIN JM M ON M.ID = R.ID WHERE R.ID > 0"
both "an extra ON conjunct"                    "$TRW SELECT M.MID FROM C R JOIN JM M ON M.ID = R.ID AND M.MID > 0"
both "an INDEXED join column (JK)"             "$TRW SELECT K.KTAG FROM C R JOIN JK K ON K.ID = R.ID"
# THE CONST TRAP: `WHERE 1=1` names NEITHER stream and does NOT move the
# engine - it still drives the table - yet term_side_only answers TRUE for a
# Const term against every window. Without the row-independent exclusion in
# the guard this cell would silently go back to the walk's order.
differs "WHERE 1=1 names neither stream"          "$TRW SELECT M.MID FROM C R JOIN JM M ON M.ID = R.ID WHERE 1=1"
# the table written FIRST already agreed, and the outer-join and ORDER BY
# forms are decided elsewhere - all three must not move
both "the table written FIRST"            "$TRW SELECT M.MID FROM JM M JOIN C R ON M.ID = R.ID"
both "LEFT JOIN from the walk"            "$TRW SELECT R.ID, M.MID FROM C R LEFT JOIN JM M ON M.ID = R.ID"
both "ORDER BY collapses it"              "$TRW SELECT M.MID FROM C R JOIN JM M ON M.ID = R.ID ORDER BY M.MID"
# a DIAMOND: 4 hangs under both 2 and 3, so it is emitted TWICE - once per
# path, each at its own place in the walk (the engine does not de-duplicate)
both "a diamond emits the node once per path" "WITH RECURSIVE C AS (SELECT ID, PARENT FROM DIA WHERE PARENT IS NULL
        UNION ALL SELECT D.ID, D.PARENT FROM DIA D JOIN C ON D.PARENT = C.ID) SELECT ID FROM C"
both "duplicate rows are kept, adjacent"      "WITH RECURSIVE C AS (SELECT ID, PARENT FROM DUP WHERE PARENT IS NULL
        UNION ALL SELECT D.ID, D.PARENT FROM DUP D JOIN C ON D.PARENT = C.ID) SELECT ID FROM C"

# --- FIRST / SKIP / ROWS over a walk, which used to REFUSE --------------
# A slice of a walk takes the rows the walk's ORDER puts first, so while
# the order was wrong the slice was a confident WRONG ROWSET and this gate
# refused it. With the order right the refusal is gone and the rows match:
# `FIRST 4` is the engine's 1,2,4,6, not a queue's 1,7,2,3.
both "FIRST 4 of a walk"                      "$TRW SELECT FIRST 4 ID FROM C"
both "SKIP 2 of a walk"                       "$TRW SELECT SKIP 2 ID FROM C"
both "ROWS 4 of a walk"                       "$TRW SELECT ID FROM C ROWS 4"

# --- the DEPTH BOUND is a RAISE, not a refusal -------------------------
# Measured: 1023 and 1024 levels answer in full, 1025 raises SQLSTATE
# 54001 *Too many concurrent executions of the same request*, and a CYCLE
# raises the same way - the engine does not detect cycles, it recurses
# until the bound. This server answered a bare 42000 for both.
CHW="UNION ALL SELECT H.ID, H.PARENT FROM CH H JOIN C ON H.PARENT = C.ID) SELECT COUNT(*) AS N FROM C"
both "1023 levels answer"   "WITH RECURSIVE C AS (SELECT ID, PARENT FROM CH WHERE ID = 3 $CHW"
both "1024 levels answer"   "WITH RECURSIVE C AS (SELECT ID, PARENT FROM CH WHERE ID = 2 $CHW"
both "1025 levels raise 54001" "WITH RECURSIVE C AS (SELECT ID, PARENT FROM CH WHERE PARENT IS NULL $CHW"
both "a cycle raises the same 54001" "WITH RECURSIVE C AS (SELECT ID, PARENT FROM CYC WHERE PARENT IS NULL
        UNION ALL SELECT Y.ID, Y.PARENT FROM CYC Y JOIN C ON Y.PARENT = C.ID) SELECT COUNT(*) AS N FROM C"

# the engine's verdict on each of the above, so this gate cannot drift
# into asserting a refusal the engine does not share
engine_errs() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$REAL" "$B")
    case "$r" in
        ERR*) echo "OK   the engine rejects it too: $1" ;;
        *) echo "DIFF the ENGINE answered [$r] - $1 must not be refused"; fail=1 ;;
    esac
}
engine_errs "a recursion that never terminates" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT N+1 FROM C) SELECT N FROM C"
engine_errs "TWO self-references in the recursive branch" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION ALL SELECT C1.N+1 FROM C C1 JOIN C C2 ON C1.N = C2.N WHERE C1.N < 3)
      SELECT N FROM C"
engine_errs "ORDER BY inside the seed" \
     "WITH RECURSIVE C AS (SELECT ID AS N FROM T WHERE ID = 1 ORDER BY ID
        UNION ALL SELECT N+1 FROM C WHERE N < 3) SELECT N FROM C ORDER BY N"
engine_errs "UNION rather than UNION ALL" \
     "WITH RECURSIVE C AS (SELECT 1 AS N FROM RDB\$DATABASE
        UNION SELECT N+1 FROM C WHERE N < 3) SELECT N FROM C"

rm -f "$A" "$B"
if [ "$ran" -lt 73 ]; then
    echo "DIFF only $ran checks ran (expected at least 73) - did one silently skip?"
    fail=1
fi
exit $fail
