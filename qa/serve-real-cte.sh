#!/bin/bash
# COMMON TABLE EXPRESSIONS - `WITH C AS (SELECT ...) SELECT ... FROM C` -
# against the REAL engine as a twin: the same driver, the same statement,
# two servers, two identical databases.
#
# A CTE is a VIEW that lives in the STATEMENT rather than the catalog:
# the same source text, the same column names, the same substitution into
# the FROM. So it is not a new mechanism here - it is the view expansion
# with a different place to look the name up, and everything that
# expansion learned over several increments arrives with it: an alias on
# the FROM item, RENAMED columns, the view's own WHERE ANDed into the
# outer one, and a CTE as a side of a JOIN.
#
# That framing is the whole design, and it is what the checks measure:
# each one below has a view-shaped twin that already passed.
#
# Two properties are specific to CTEs and get their own checks:
#
#   * The COLUMN LIST renames: `WITH C (A, B) AS (SELECT ID, SALARY ...)`
#     makes the CTE's columns A and B, positionally. That is the same
#     renaming a view does through RDB$RELATION_FIELDS, which is why it
#     costs nothing here - but it is written differently, so it is
#     parsed differently and checked separately.
#   * A CTE SHADOWS a table of the same name for its statement.
#
# And the refusal that matters most: a CTE name left in the FROM because
# its body could not be expanded must REFUSE. It names no relation, so
# falling through would reach the fixed-answer fallback and reply 4242 to
# a query over real tables - the failure mode this project keeps closing.
#
#   qa/serve-real-cte.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4547}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-cte-crab.fdb"
B="$D/fc-cte-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (ID INTEGER, DEPT_ID INTEGER, SALARY INTEGER, NAME VARCHAR(6));
CREATE TABLE DEPT (ID INTEGER, DNAME VARCHAR(6));
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 'c');
INSERT INTO EMP VALUES (4, 3,  50, 'd');
INSERT INTO EMP VALUES (5, NULL, 400, 'e');
INSERT INTO DEPT VALUES (1, 'one');
INSERT INTO DEPT VALUES (2, 'two');
INSERT INTO DEPT VALUES (3, 'three');
INSERT INTO DEPT VALUES (9, 'empty');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cte.log 2>&1 &
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

# --- 0. the control ----------------------------------------------------
both "the same query without a CTE" \
     "SELECT COUNT(*) FROM EMP WHERE SALARY > 150"

# --- 1. the CTE as a source -------------------------------------------
both "a CTE counted" \
     "WITH C AS (SELECT ID FROM EMP WHERE SALARY > 150) SELECT COUNT(*) FROM C"
both "a CTE projected" \
     "WITH C AS (SELECT ID, SALARY FROM EMP WHERE SALARY > 150)
      SELECT ID FROM C ORDER BY ID"
both "the CTE's own WHERE and the outer one both apply" \
     "WITH C AS (SELECT ID, SALARY FROM EMP WHERE SALARY > 60)
      SELECT ID FROM C WHERE SALARY < 350 ORDER BY ID"
both "a column the CTE selects but the outer query does not" \
     "WITH C AS (SELECT ID, SALARY FROM EMP) SELECT ID FROM C WHERE SALARY > 150 ORDER BY ID"
both "an ALIAS on the CTE in the FROM" \
     "WITH C AS (SELECT ID, SALARY FROM EMP)
      SELECT X.ID FROM C X WHERE X.SALARY > 150 ORDER BY X.ID"
both "the CTE's own name as a qualifier" \
     "WITH C AS (SELECT ID, SALARY FROM EMP)
      SELECT C.ID FROM C WHERE C.SALARY > 150 ORDER BY C.ID"

# --- 2. the COLUMN LIST, which renames --------------------------------
both "a renaming column list" \
     "WITH C (A, B) AS (SELECT ID, SALARY FROM EMP)
      SELECT A FROM C WHERE B > 150 ORDER BY A"
both "... projecting both renamed columns" \
     "WITH C (A, B) AS (SELECT ID, SALARY FROM EMP)
      SELECT A, B FROM C WHERE B > 150 ORDER BY A"
both "... with a star" \
     "WITH C (A, B) AS (SELECT ID, SALARY FROM EMP)
      SELECT * FROM C WHERE B > 150 ORDER BY A"
both "... and an ORDER BY on a renamed column" \
     "WITH C (A, B) AS (SELECT ID, SALARY FROM EMP) SELECT A FROM C ORDER BY B DESC"

# --- 3. what the expanded query flows into ----------------------------
both "an aggregate over a CTE" \
     "WITH C AS (SELECT ID, SALARY FROM EMP) SELECT MAX(SALARY), COUNT(*) FROM C"
both "GROUP BY over a CTE" \
     "WITH C AS (SELECT DEPT_ID, SALARY FROM EMP)
      SELECT DEPT_ID, COUNT(*) FROM C GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "GROUP BY with a HAVING" \
     "WITH C AS (SELECT DEPT_ID, SALARY FROM EMP)
      SELECT DEPT_ID, COUNT(*) FROM C GROUP BY DEPT_ID HAVING COUNT(*) > 1 ORDER BY DEPT_ID"
both "an expression over a CTE" \
     "WITH C AS (SELECT ID, SALARY FROM EMP) SELECT SALARY + 1 FROM C ORDER BY ID"
both "DISTINCT over a CTE" \
     "WITH C AS (SELECT DEPT_ID FROM EMP) SELECT DISTINCT DEPT_ID FROM C ORDER BY DEPT_ID"
both "FIRST over a CTE" \
     "WITH C AS (SELECT ID FROM EMP) SELECT FIRST 2 ID FROM C ORDER BY ID"

# --- 4. a CTE as a side of a JOIN -------------------------------------
both "a CTE joined to a table" \
     "WITH C AS (SELECT ID, DEPT_ID FROM EMP)
      SELECT COUNT(*) FROM C JOIN DEPT D ON C.DEPT_ID = D.ID"
both "... projecting through it" \
     "WITH C AS (SELECT ID, DEPT_ID FROM EMP)
      SELECT C.ID FROM C JOIN DEPT D ON C.DEPT_ID = D.ID ORDER BY C.ID"
both "a CTE on the PADDED side of a LEFT join" \
     "WITH C AS (SELECT ID, DEPT_ID FROM EMP WHERE SALARY > 150)
      SELECT COUNT(*) FROM DEPT D LEFT JOIN C ON C.DEPT_ID = D.ID"
both "a renamed CTE in a join" \
     "WITH C (EID, DID) AS (SELECT ID, DEPT_ID FROM EMP)
      SELECT COUNT(*) FROM C JOIN DEPT D ON C.DID = D.ID"

# --- 5. several CTEs, and shadowing -----------------------------------
both "two CTEs, the FIRST used" \
     "WITH C AS (SELECT ID FROM EMP), D AS (SELECT ID FROM DEPT) SELECT COUNT(*) FROM C"
both "two CTEs, the SECOND used" \
     "WITH C AS (SELECT ID FROM EMP), D AS (SELECT ID FROM DEPT) SELECT COUNT(*) FROM D"
both "two CTEs JOINED to each other" \
     "WITH C AS (SELECT ID, DEPT_ID FROM EMP), D AS (SELECT ID FROM DEPT)
      SELECT COUNT(*) FROM C JOIN D ON C.DEPT_ID = D.ID"
# a CTE SHADOWS a table of the same name for its statement
both "a CTE that shadows a real table" \
     "WITH DEPT AS (SELECT ID FROM EMP WHERE SALARY > 150) SELECT COUNT(*) FROM DEPT"

# --- 6. the refusals --------------------------------------------------
# `WITH RECURSIVE` is a FIXPOINT rather than a substitution - and this
# body never names itself, so it is an ORDINARY CTE that happens to
# carry the keyword, and must answer like one. The fixpoint itself has
# its own gate (qa/serve-real-recursive.sh).
both "WITH RECURSIVE on a body that never names itself" \
     "WITH RECURSIVE C AS (SELECT ID FROM EMP) SELECT COUNT(*) FROM C"
# A CTE body the INLINING cannot rewrite - one that GROUPS, stars or
# JOINS - is MATERIALISED instead: it is a derived table by another name,
# so `FROM C` becomes `FROM (<body>) C`. These three refused until the
# increment that made a grouped plan a row source.
both "a CTE whose body GROUPS" \
     "WITH C AS (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID)
      SELECT C.DEPT_ID, C.N FROM C ORDER BY C.DEPT_ID"
both "... filtered by the OUTER query on a folded column" \
     "WITH C AS (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID)
      SELECT C.DEPT_ID FROM C WHERE C.N > 1 ORDER BY C.DEPT_ID"
both "... with a HAVING inside" \
     "WITH C AS (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID
                 HAVING COUNT(*) > 1)
      SELECT C.DEPT_ID FROM C ORDER BY C.DEPT_ID"
both "a CTE whose body is a star" \
     "WITH C AS (SELECT * FROM EMP) SELECT C.ID FROM C ORDER BY C.ID"
both "a CTE whose body is a JOIN" \
     "WITH C AS (SELECT E.ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID)
      SELECT C.ID FROM C ORDER BY C.ID"
both "FIRST over a materialised CTE" \
     "WITH C AS (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID)
      SELECT FIRST 2 C.DEPT_ID FROM C ORDER BY C.DEPT_ID"
# a materialised CTE as one SIDE of a join refused until a derived table
# could BE a side; now it can, so the CTE is spliced into that position
# like any other
both "a materialised CTE in a JOIN" \
     "WITH C AS (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID)
      SELECT COUNT(*) FROM C JOIN DEPT D ON C.DEPT_ID = D.ID"
both "... projecting the CTE's folded column" \
     "WITH C AS (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID)
      SELECT C.N FROM C JOIN DEPT D ON C.DEPT_ID = D.ID ORDER BY C.N"
both "TWO CTEs joined to each other" \
     "WITH C AS (SELECT DEPT_ID FROM EMP), E AS (SELECT ID FROM DEPT)
      SELECT COUNT(*) FROM C JOIN E ON C.DEPT_ID = E.ID"

rm -f "$A" "$B"
if [ "$ran" -lt 35 ]; then
    echo "DIFF only $ran checks ran (expected at least 35) - did one silently skip?"
    fail=1
fi
exit $fail
