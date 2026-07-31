#!/bin/bash
# A SUBQUERY IN THE SELECT LIST - `SELECT ID, (SELECT COUNT(*) FROM D)
# FROM T` - against the REAL engine as a twin: the same driver, the same
# statement, two servers, two identical databases.
#
# The WHERE clause has taken subqueries for many increments: they are
# LIFTED out of the text, evaluated, and folded back in as ordinary
# tokens before the predicate parser ever sees them. The select list
# could not hold one at all.
#
# The conversion reuses that lifting. A subquery naming no outer column
# is a CONSTANT for the whole statement, so it is evaluated once and
# folded back into the query TEXT as the literal it computed, and the
# statement is re-planned - the same "rewrite and re-plan" the view
# expansion uses. Every select-list shape then works over it for free: an
# alias, an expression around it, a CASE, an ORDER BY, a grouped query.
#
# Three laws, each probed against the engine before the code was written:
#
#   * NO ROWS answers NULL - not an empty result and not an error.
#   * MORE THAN ONE ROW is an error: "multiple rows in singleton select"
#     (SQLSTATE 21000). Taking the first row would be a wrong answer
#     where the engine raises, so the fold refuses to guess.
#   * The output column is named by the SUBQUERY's own select item -
#     `(SELECT COUNT(*) ...)` describes as COUNT, `(SELECT ID ...)` as ID
#     - and NOT by the literal it folded to. Getting this wrong is
#     invisible in the values and visible in every driver's row objects,
#     so the checks compare whole JSON, keys included.
#
# Two neighbours fell out of the same work and are checked here because
# the fold produces them:
#
#   * `SELECT 3 FROM T` REFUSED. An unquoted identifier cannot start with
#     a digit, but `ident_ok` accepted "3", so a numeric literal in the
#     select list was read as a COLUMN NAMED 3 and never found. `NULL`
#     and `'x'` worked, which is what kept it hidden - and a folded
#     subquery lands exactly there.
#   * `SELECT -3` describes as CONSTANT while `SELECT -SALARY` describes
#     BLANK (probed). A negated literal is still a constant.
#
#   qa/serve-real-selectsubq.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4545}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ssq-crab.fdb"
B="$D/fc-ssq-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# DEPT has THREE rows and EMP has FOUR, so a fold that returned the wrong
# table's count is visible; DEPT 3 is referenced by exactly one employee.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (ID INTEGER, DEPT_ID INTEGER, SALARY INTEGER, NAME VARCHAR(6));
CREATE TABLE DEPT (ID INTEGER, DNAME VARCHAR(6), BUDGET NUMERIC(9,2));
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 'c');
INSERT INTO EMP VALUES (4, 3,  50, 'd');
INSERT INTO DEPT VALUES (1, 'one',   10.50);
INSERT INTO DEPT VALUES (2, 'two',   20.25);
INSERT INTO DEPT VALUES (3, 'three', 30.75);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-selectsubq.log 2>&1 &
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

# whole JSON, KEYS included - the naming law is half this increment
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
# fire-crab against ISQL, for shapes this driver cannot decode from the
# ENGINE (a text column arrives as `string right truncation` from the
# engine itself, so the twin has no oracle there)
vs_isql() { # <label> <sql> <isql select body>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A" \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
             try{console.log(JSON.parse(s).map(r=>Object.values(r).map(v=>String(v).replace(/\s+$/,"")).join("|")).join(" "))}
             catch(e){console.log("PARSE_ERR")}})' 2>/dev/null)
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$B" <<EOF 2>&1 | sed 's/[[:space:]]*$//' | grep -v '^$' | paste -sd' '
SET HEADING OFF;
$3;
EOF
)
    if [ "$a" = "$b" ] && [ -n "$a" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     isql:   $b"
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

# --- 0. the controls ---------------------------------------------------
both "a plain select" "SELECT ID FROM EMP ORDER BY ID"
both "a subquery in the WHERE, as before" \
     "SELECT COUNT(*) FROM EMP WHERE DEPT_ID IN (SELECT ID FROM DEPT)"

# --- 1. the subquery as a select item ---------------------------------
both "an aggregate subquery" "SELECT ID, (SELECT COUNT(*) FROM DEPT) FROM EMP ORDER BY ID"
both "as the ONLY item" "SELECT (SELECT COUNT(*) FROM DEPT) FROM EMP WHERE ID = 1"
both "MAX, naming the column MAX" \
     "SELECT ID, (SELECT MAX(ID) FROM DEPT) FROM EMP WHERE ID = 1"
both "a plain COLUMN subquery, named after it" \
     "SELECT ID, (SELECT ID FROM DEPT WHERE ID = 2) FROM EMP WHERE ID = 1"
# a TEXT column folded from a subquery is compared against ISQL: this
# driver cannot decode the ENGINE's own answer for that shape
# (`string right truncation`), so the twin has no oracle for it
vs_isql "a TEXT column subquery, against isql" \
        "SELECT ID, (SELECT DNAME FROM DEPT WHERE ID = 2) FROM EMP WHERE ID = 1" \
        "SELECT ID || '|' || (SELECT DNAME FROM DEPT WHERE ID = 2) FROM EMP WHERE ID = 1"
both "a scaled NUMERIC subquery" \
     "SELECT ID, (SELECT BUDGET FROM DEPT WHERE ID = 2) FROM EMP WHERE ID = 1"
both "with an explicit ALIAS" \
     "SELECT ID, (SELECT MAX(ID) FROM DEPT) AS M FROM EMP WHERE ID = 1"
both "TWO subqueries in one list" \
     "SELECT (SELECT COUNT(*) FROM DEPT), (SELECT MAX(ID) FROM DEPT) FROM EMP WHERE ID = 1"
both "the subquery carries its own WHERE" \
     "SELECT ID, (SELECT COUNT(*) FROM DEPT WHERE ID > 1) FROM EMP ORDER BY ID"
both "an aggregate over a filtered subquery" \
     "SELECT ID, (SELECT SUM(BUDGET) FROM DEPT WHERE ID < 3) FROM EMP WHERE ID = 1"

# --- 2. the two boundary laws -----------------------------------------
both "NO ROWS answers NULL (aggregate)" \
     "SELECT ID, (SELECT MAX(ID) FROM DEPT WHERE ID > 99) FROM EMP WHERE ID = 1"
both "NO ROWS answers NULL (plain column)" \
     "SELECT ID, (SELECT ID FROM DEPT WHERE ID > 99) FROM EMP WHERE ID = 1"
# more than one row is an ERROR on both servers, with the engine's words
ran=$((ran + 1))
a=$(query "SELECT ID, (SELECT ID FROM DEPT) FROM EMP WHERE ID = 1" "$PORT" "$A")
b=$(query "SELECT ID, (SELECT ID FROM DEPT) FROM EMP WHERE ID = 1" "$REAL" "$B")
case "$a$b" in
    *"ultiple rows in singleton"*"ultiple rows in singleton"*)
        echo "OK   more than one row raises on BOTH: $a" ;;
    *) echo "DIFF singleton select"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1 ;;
esac

# --- 3. what the folded value flows into ------------------------------
both "inside an ARITHMETIC expression" \
     "SELECT ID + (SELECT COUNT(*) FROM DEPT) FROM EMP ORDER BY ID"
both "inside a CASE condition" \
     "SELECT CASE WHEN (SELECT COUNT(*) FROM DEPT) > 2 THEN 1 ELSE 0 END
      FROM EMP WHERE ID = 1"
both "inside COALESCE" \
     "SELECT COALESCE((SELECT MAX(ID) FROM DEPT WHERE ID > 99), -1) FROM EMP WHERE ID = 1"
both "inside a CAST" \
     "SELECT CAST((SELECT COUNT(*) FROM DEPT) AS VARCHAR(4)) FROM EMP WHERE ID = 1"
both "in a GROUPED query" \
     "SELECT DEPT_ID, COUNT(*) + (SELECT COUNT(*) FROM DEPT) FROM EMP
      GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "ORDER BY the folded column's alias" \
     "SELECT ID, (SELECT COUNT(*) FROM DEPT) AS C FROM EMP ORDER BY C, ID"
both "with a WHERE on the outer table" \
     "SELECT ID, (SELECT COUNT(*) FROM DEPT) FROM EMP WHERE SALARY > 150 ORDER BY ID"
both "with FIRST over it" \
     "SELECT FIRST 2 ID, (SELECT COUNT(*) FROM DEPT) FROM EMP ORDER BY ID"

# --- 4. the LITERAL select item, which the fold produces --------------
both "a bare INTEGER literal" "SELECT ID, 3 FROM EMP WHERE ID = 1"
both "an integer literal ALONE" "SELECT 3 FROM EMP WHERE ID = 1"
both "an aliased integer literal" "SELECT ID, 3 AS C FROM EMP WHERE ID = 1"
both "a DECIMAL literal" "SELECT ID, 1.5 FROM EMP WHERE ID = 1"
both "a NEGATED literal is a CONSTANT" "SELECT ID, -3 FROM EMP WHERE ID = 1"
both "a NEGATED column is not" "SELECT ID, -SALARY FROM EMP WHERE ID = 1"
both "a string literal, as before" "SELECT ID, 'x' FROM EMP WHERE ID = 1"
both "NULL, as before" "SELECT ID, NULL FROM EMP WHERE ID = 1"
both "a QUOTED digit is still a column" \
     "SELECT COUNT(*) FROM EMP WHERE ID = 1"

# --- 5. the CORRELATED neighbour --------------------------------------
# A correlated subquery has a different value per OUTER ROW, so it cannot
# be folded once for the statement - it REFUSED here until the increment
# that gave it a per-key LOOKUP TABLE instead. Compared now, with
# qa/serve-real-corrsubq.sh owning the shape: a refusal check that keeps
# passing after the refusal is lifted passes for the wrong reason.
both "a CORRELATED subquery in the select list" \
     "SELECT E.ID, (SELECT D.ID FROM DEPT D WHERE D.ID = E.DEPT_ID) FROM EMP E ORDER BY E.ID"
both "... with an aggregate" \
     "SELECT E.ID, (SELECT COUNT(*) FROM DEPT D WHERE D.ID = E.DEPT_ID) FROM EMP E ORDER BY E.ID"

rm -f "$A" "$B"
if [ "$ran" -lt 33 ]; then
    echo "DIFF only $ran checks ran (expected at least 33) - did one silently skip?"
    fail=1
fi
exit $fail
