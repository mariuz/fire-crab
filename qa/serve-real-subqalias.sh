#!/bin/bash
# SUBQUERIES WHOSE TABLES CARRY ALIASES - `WHERE E.DEPT_ID IN (SELECT
# D.ID FROM DEPT D)` - against the REAL engine as a twin: the same
# driver, the same statement, two servers, two identical databases.
#
# Subqueries have worked here for many increments, and almost every one
# of them refused the moment either table was ALIASED - which is how most
# people write them. Two separate causes, both about SCOPE:
#
#   1. The pass that strips a table's qualifiers rewrote the WHOLE
#      statement, INCLUDING the text inside the subquery. `(SELECT 1 FROM
#      DEPT D WHERE D.ID = EMP.DEPT_ID)` names the OUTER table on
#      purpose; stripping that qualifier left a bare `DEPT_ID`, which the
#      inner table does not have - and in other shapes DOES have, meaning
#      something else entirely. A NESTED QUERY IS A DIFFERENT SCOPE, so
#      the rewrite now copies such a span verbatim.
#
#   2. The subquery's own clauses may qualify by the INNER table's name
#      or its alias (`SELECT D.ID FROM DEPT D WHERE D.ID > 1`), and its
#      resolver looked those names up unqualified. The correlation split
#      NEEDS the qualifiers to tell the two sides apart, so they are
#      stripped AFTER that split rather than before it - an ordering the
#      code says out loud, because reversing it silently changes which
#      column the correlation names.
#
# The controls matter as much as the checks: every shape is run in its
# UNALIASED spelling too, since the aliases are the variable under test
# and everything else must be identical.
#
#   qa/serve-real-subqalias.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4551}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-sqa-crab.fdb"
B="$D/fc-sqa-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# EMP 5 has a NULL department (NOT IN's third answer) and DEPT 9 has no
# employees, so a semi-join and its negation select different rows.
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

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-subqalias.log 2>&1 &
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

# --- 1. IN / NOT IN, with and without aliases -------------------------
both "IN, unaliased (the control)" \
     "SELECT COUNT(*) FROM EMP WHERE DEPT_ID IN (SELECT ID FROM DEPT)"
both "IN, the INNER table aliased" \
     "SELECT COUNT(*) FROM EMP WHERE DEPT_ID IN (SELECT D.ID FROM DEPT D)"
both "IN, the OUTER table aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID IN (SELECT ID FROM DEPT)"
both "IN, BOTH aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID IN (SELECT D.ID FROM DEPT D)"
both "IN, with an inner WHERE" \
     "SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID IN (SELECT D.ID FROM DEPT D WHERE D.ID > 1)"
both "NOT IN, both aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID NOT IN (SELECT D.ID FROM DEPT D WHERE D.ID > 2)"
both "IN, selecting the rows" \
     "SELECT E.ID FROM EMP E WHERE E.DEPT_ID IN (SELECT D.ID FROM DEPT D) ORDER BY E.ID"

# --- 2. a SCALAR subquery on the right of a comparison ----------------
both "scalar, unaliased (the control)" \
     "SELECT COUNT(*) FROM EMP WHERE SALARY > (SELECT AVG(SALARY) FROM EMP)"
both "scalar, the inner table aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE E.SALARY > (SELECT AVG(E2.SALARY) FROM EMP E2)"
both "scalar over the OTHER table, aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID > (SELECT MIN(D.ID) FROM DEPT D)"
both "scalar with an inner WHERE" \
     "SELECT COUNT(*) FROM EMP E WHERE E.SALARY > (SELECT MIN(E2.SALARY) FROM EMP E2 WHERE E2.ID > 1)"

# --- 3. a subquery in the SELECT LIST, aliased ------------------------
both "constant subquery, inner aliased" \
     "SELECT E.ID, (SELECT MAX(D.ID) FROM DEPT D) FROM EMP E ORDER BY E.ID"
both "correlated subquery, both aliased" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) FROM DEPT D ORDER BY D.ID"
both "correlated with an inner residual, aliased" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID AND E.SALARY > 150)
      FROM DEPT D ORDER BY D.ID"

# --- 4. EXISTS, which is where the SCOPE bug showed -------------------
# the outer table names itself inside the subquery on purpose; a rewrite
# that stripped that qualifier left a bare column the inner table lacks
both "EXISTS, unaliased (the control)" \
     "SELECT COUNT(*) FROM EMP WHERE EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = EMP.DEPT_ID)"
both "EXISTS, the OUTER table aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = E.DEPT_ID)"
# NOT EXISTS is a TWO-VALUED test on rows - "no inner row matches" -
# while the `NOT IN` it rewrites to is three-valued and answers UNKNOWN
# for a NULL left side. EMP 5's department is NULL, so it matches NOTHING
# and therefore SATISFIES NOT EXISTS; the rewrite used to drop it and
# answer 0 where the engine answers 1. Both spellings are checked because
# the bug was in the rewrite, not in the aliasing.
both "NOT EXISTS keeps the row whose key is NULL" \
     "SELECT COUNT(*) FROM EMP WHERE NOT EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = EMP.DEPT_ID)"
both "NOT EXISTS, the outer table aliased" \
     "SELECT COUNT(*) FROM EMP E WHERE NOT EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = E.DEPT_ID)"
both "... and WHICH row it is" \
     "SELECT E.ID FROM EMP E WHERE NOT EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = E.DEPT_ID)
      ORDER BY E.ID"
# the positive form must not have moved
both "EXISTS drops the NULL-key row" \
     "SELECT E.ID FROM EMP E WHERE EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = E.DEPT_ID)
      ORDER BY E.ID"
# and a literal NOT IN is the OPPOSITE case: there the NULL genuinely
# does poison, and the engine drops every row
both "a literal NOT IN still poisons on NULL" \
     "SELECT COUNT(*) FROM EMP WHERE DEPT_ID NOT IN (SELECT ID FROM DEPT)"
both "EXISTS selecting the rows, outer aliased" \
     "SELECT E.ID FROM EMP E WHERE EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = E.DEPT_ID)
      ORDER BY E.ID"
both "EXISTS with an inner residual" \
     "SELECT COUNT(*) FROM EMP E
      WHERE EXISTS (SELECT 1 FROM DEPT WHERE DEPT.ID = E.DEPT_ID AND DEPT.ID > 1)"

# --- 5. the qualified WHERE terms around them must not move -----------
both "a qualified outer WHERE beside a subquery" \
     "SELECT COUNT(*) FROM EMP E WHERE E.SALARY > 60 AND E.DEPT_ID IN (SELECT D.ID FROM DEPT D)"
both "two subqueries in one WHERE" \
     "SELECT COUNT(*) FROM EMP E
      WHERE E.DEPT_ID IN (SELECT D.ID FROM DEPT D) AND E.SALARY > (SELECT MIN(E2.SALARY) FROM EMP E2)"
both "a plain qualified WHERE" "SELECT COUNT(*) FROM EMP E WHERE E.SALARY > 150"
both "a qualified projection beside one" \
     "SELECT E.ID, E.NAME FROM EMP E WHERE E.DEPT_ID IN (SELECT D.ID FROM DEPT D) ORDER BY E.ID"

# --- 6. what still refuses, and why -----------------------------------
# A correlated EXISTS whose INNER table is aliased is not answered yet:
# the correlation split reads the alias, but something later in the
# EXISTS path still resolves against the inner table's own name. It
# REFUSES rather than answering, and the shapes above show the same
# correlation working through IN, through a scalar comparison and in the
# select list - so this is a gap in one path, named here as the next
# slice rather than left to be discovered.
refuses "a correlated EXISTS whose INNER table is aliased" \
        "SELECT COUNT(*) FROM EMP WHERE EXISTS (SELECT 1 FROM DEPT D WHERE D.ID = EMP.DEPT_ID)"
refuses "... with both aliased" \
        "SELECT COUNT(*) FROM EMP E WHERE EXISTS (SELECT 1 FROM DEPT D WHERE D.ID = E.DEPT_ID)"

rm -f "$A" "$B"
if [ "$ran" -lt 28 ]; then
    echo "DIFF only $ran checks ran (expected at least 28) - did one silently skip?"
    fail=1
fi
exit $fail
