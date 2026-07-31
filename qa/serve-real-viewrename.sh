#!/bin/bash
# A view whose columns are RENAMED, a QUALIFIED column in a one-table
# query, and an ALIAS on a joined column - against the REAL engine as a
# twin: the same driver, the same statement, two servers, two identical
# databases.
#
# These arrived together because the first one could not be fixed without
# the other two, and each was a WRONG ANSWER rather than a refusal:
#
#   1. A RENAMED view column answered under the BASE table's name.
#      `SELECT EID FROM VREN` returned the right value called ID. Every
#      value was right and every NAME was wrong, and a driver builds its
#      row objects from those names - so `row.EID` was undefined. The
#      sharpest case is a view that SWAPS two names
#      (`SELECT NAME AS ID, ID AS NAME`): the values then land on each
#      other's names, and `row.ID` is a number on one server and a string
#      on the other. Every check here compares the KEYS as well as the
#      values, which is the only way that shows.
#
#   2. `SELECT E.ID FROM EMP E` REFUSED. The join resolver has always
#      understood qualified names - it must, since that is the only way
#      to say which side you mean - but the single-relation path never
#      did, so qualifying a column in a one-table query (ordinary SQL,
#      and what the view rewrite produces) was an error.
#
#   3. An ALIAS on a joined column was DROPPED. That is not only a wrong
#      name: `SELECT E.ID AS EMPID, D.ID AS DEPTID` produced two output
#      columns BOTH called ID, and a driver keying by name kept one of
#      them - two columns asked for, one column delivered.
#
# And a fourth, which is what connects them: a grouped key answers to
# BOTH names when the select list renamed it, so `SELECT DEPT_ID AS D2
# ... GROUP BY DEPT_ID ORDER BY DEPT_ID` sorts by the key. That looks
# exotic written by hand and is exactly what a view produces.
#
#   qa/serve-real-viewrename.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4542}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-vren-crab.fdb"
B="$D/fc-vren-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (ID INTEGER, DEPT_ID INTEGER, SALARY INTEGER, NAME VARCHAR(10));
CREATE TABLE DEPT (ID INTEGER, DNAME VARCHAR(10));
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 'c');
INSERT INTO EMP VALUES (4, 3,  50, 'd');
INSERT INTO DEPT VALUES (1, 'one');
INSERT INTO DEPT VALUES (2, 'two');
INSERT INTO DEPT VALUES (3, 'three');
COMMIT;
-- every column renamed
CREATE VIEW VREN AS
  SELECT ID AS EID, DEPT_ID AS DID, SALARY AS PAY, NAME AS ENAME FROM EMP;
-- renamed AND carrying its own WHERE
CREATE VIEW VRENW AS
  SELECT ID AS EID, DEPT_ID AS DID, NAME AS ENAME FROM EMP WHERE SALARY > 150;
-- the SWAP: two names trade places, so a two-pass substitution corrupts
-- it and a describe that reports the base's names mislabels BOTH columns
CREATE VIEW VSWAP AS SELECT NAME AS ID, ID AS NAME FROM EMP;
-- only SOME columns renamed
CREATE VIEW VPART AS SELECT ID, DEPT_ID AS DID, NAME FROM EMP;
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-viewrename.log 2>&1 &
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

# The comparison is of the whole JSON, keys included - the keys are what
# a driver builds from the describe, and every bug in this increment was
# visible only in them.
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

# --- 1. a RENAMED view keeps the VIEW's names --------------------------
both "a renamed column" "SELECT EID FROM VREN ORDER BY EID"
both "several of them" "SELECT EID, PAY, ENAME FROM VREN ORDER BY EID"
both "the star, which lists them all" "SELECT * FROM VREN ORDER BY EID"
both "a view that renames only SOME" "SELECT * FROM VPART ORDER BY ID"
both "the view's own WHERE still applies" "SELECT * FROM VRENW ORDER BY EID"
# the SWAP: values must land on the names the engine puts them on
both "a view that SWAPS two names" "SELECT * FROM VSWAP ORDER BY NAME"
both "... naming them explicitly" "SELECT ID, NAME FROM VSWAP ORDER BY NAME"
# an explicit alias wins over the view's name, as it does over a column's
both "an alias over a renamed column" "SELECT EID AS X FROM VREN ORDER BY EID"
# and the renamed name works everywhere a name can appear
both "a renamed column in the WHERE" \
     "SELECT EID FROM VREN WHERE PAY > 150 ORDER BY EID"
both "... in the ORDER BY, unselected" "SELECT EID FROM VREN ORDER BY PAY DESC"
both "... under an aggregate" "SELECT MAX(PAY), COUNT(*) FROM VREN"
both "... as a GROUP BY key" \
     "SELECT DID, COUNT(*) FROM VREN GROUP BY DID ORDER BY DID"
both "... with a HAVING over it" \
     "SELECT DID, MAX(PAY) FROM VREN GROUP BY DID HAVING MAX(PAY) > 150 ORDER BY DID"
both "... in an expression" "SELECT EID + 1 FROM VREN ORDER BY EID"

# --- 2. a QUALIFIED column in a ONE-TABLE query ------------------------
both "qualified by the table's ALIAS" "SELECT E.ID FROM EMP E ORDER BY E.ID"
both "qualified by the TABLE's own name" "SELECT EMP.ID FROM EMP ORDER BY EMP.ID"
both "a qualified star" "SELECT E.* FROM EMP E ORDER BY E.ID"
both "qualified in the WHERE" \
     "SELECT E.ID FROM EMP E WHERE E.SALARY > 150 ORDER BY E.ID"
both "qualified with an alias of its own" \
     "SELECT E.ID AS X FROM EMP E ORDER BY E.ID"
both "qualified in an expression" "SELECT E.ID + 1 FROM EMP E ORDER BY E.ID"
both "qualified as a GROUP BY key" \
     "SELECT E.DEPT_ID, COUNT(*) FROM EMP E GROUP BY E.DEPT_ID ORDER BY E.DEPT_ID"
both "qualified under an aggregate and a HAVING" \
     "SELECT E.DEPT_ID, MAX(E.SALARY) FROM EMP E GROUP BY E.DEPT_ID
      HAVING MAX(E.SALARY) > 150 ORDER BY E.DEPT_ID"
# the unqualified spellings must not have moved
both "the bare name still works" "SELECT ID FROM EMP E ORDER BY ID"
both "and a bare WHERE" "SELECT COUNT(*) FROM EMP WHERE NAME LIKE 'a%'"

# --- 3. a grouped key answers to BOTH names ---------------------------
both "an aliased key, sorted by the SOURCE name" \
     "SELECT DEPT_ID AS D2, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "... sorted by the ALIAS" \
     "SELECT DEPT_ID AS D2, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY D2"
both "... sorted by ORDINAL" \
     "SELECT DEPT_ID AS D2, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY 1 DESC"

# --- 4. an ALIAS on a JOINED column -----------------------------------
both "an alias on a joined column" \
     "SELECT E.NAME AS X FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID"
# the collapse: two columns whose BASE names agree
both "two same-named columns under different aliases" \
     "SELECT E.ID AS EMPID, D.ID AS DEPTID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID
      ORDER BY E.ID"
both "an unaliased joined column keeps its own name" \
     "SELECT E.ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID"
both "an aliased aggregate over a join" \
     "SELECT COUNT(*) AS N FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID"

# --- 5. a RENAMED view as a side of a JOIN ----------------------------
both "a renamed view joined, by count" \
     "SELECT COUNT(*) FROM VREN V JOIN DEPT D ON V.DID = D.ID"
both "... projecting its renamed columns" \
     "SELECT V.EID, V.PAY FROM VREN V JOIN DEPT D ON V.DID = D.ID ORDER BY V.EID"
both "... a renamed TEXT column" \
     "SELECT V.ENAME FROM VREN V JOIN DEPT D ON V.DID = D.ID ORDER BY V.EID"
both "... with a WHERE on a renamed column" \
     "SELECT V.EID FROM VREN V JOIN DEPT D ON V.DID = D.ID WHERE V.PAY > 150
      ORDER BY V.EID"
both "... grouped" \
     "SELECT D.ID, COUNT(*) FROM VREN V JOIN DEPT D ON V.DID = D.ID
      GROUP BY D.ID ORDER BY D.ID"
both "... aggregated over a renamed column" \
     "SELECT SUM(V.PAY) FROM VREN V JOIN DEPT D ON V.DID = D.ID"
both "an UNALIASED renamed view in a join" \
     "SELECT COUNT(*) FROM VREN JOIN DEPT ON VREN.DID = DEPT.ID"
both "... projecting through its own name" \
     "SELECT VREN.EID FROM VREN JOIN DEPT ON VREN.DID = DEPT.ID ORDER BY VREN.EID"
both "two renamed views joined together" \
     "SELECT COUNT(*) FROM VREN V JOIN VRENW W ON V.EID = W.EID"
both "a renamed view on the PADDED side of a LEFT join" \
     "SELECT COUNT(*) FROM DEPT D LEFT JOIN VRENW V ON V.DID = D.ID"
both "... on the PRESERVED side" \
     "SELECT COUNT(*) FROM VRENW V LEFT JOIN DEPT D ON V.DID = D.ID"
both "a renamed view in a CROSS join" \
     "SELECT COUNT(*) FROM VREN V CROSS JOIN DEPT D"
# the control: an unrenamed view through the same path
both "an unrenamed view is unaffected" \
     "SELECT COUNT(*) FROM VPART V JOIN DEPT D ON V.DID = D.ID"

# --- 6. the refusal --------------------------------------------------
# A BARE reference to a renamed view column inside a JOIN: with more than
# one side in scope, the same word can be this view's renamed column and
# another table's real one, and only the qualifier says which. The engine
# resolves it; this server refuses rather than guessing a side.
refuses "a BARE renamed column in a join" \
        "SELECT EID FROM VREN V JOIN DEPT D ON V.DID = D.ID"
refuses "... and in the ON" \
        "SELECT COUNT(*) FROM VREN V JOIN DEPT D ON EID > 0"

rm -f "$A" "$B"
if [ "$ran" -lt 41 ]; then
    echo "DIFF only $ran checks ran (expected at least 41) - did one silently skip?"
    fail=1
fi
exit $fail
