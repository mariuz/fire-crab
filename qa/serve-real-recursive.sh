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
if [ "$ran" -lt 43 ]; then
    echo "DIFF only $ran checks ran (expected at least 43) - did one silently skip?"
    fail=1
fi
exit $fail
