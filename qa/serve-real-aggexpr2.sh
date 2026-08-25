#!/bin/bash
# An AGGREGATE INSIDE AN EXPRESSION - `SUM(A) + 1`, `MAX(A) - MIN(A)`,
# `CAST(SUM(A) AS VARCHAR(10))` - and SORTING BY A COMPUTED OUTPUT
# COLUMN, against the REAL engine as a twin: the same driver, the same
# statement, two servers, two identical databases.
#
# The select list could hold an aggregate (`SELECT SUM(A)`) or an
# expression (`SELECT A + 1`) but never one INSIDE the other, because the
# two live in different grammars: an aggregate was a select-list ITEM
# while an expression is a TREE, and the tree had no leaf for a fold.
# Every shape below refused - including `SELECT COUNT(*) * 2`.
#
# The conversion is one idea: an aggregate is a leaf that has no value
# for a ROW, only for a GROUP. So each one becomes a SLOT of the group
# row, and the surrounding expression is then an ordinary expression over
# that row - the same trick the join uses when it runs the ordinary
# expression resolver over a combined row. A query with no GROUP BY is
# the single global group, which is what makes `SELECT SUM(A) + 1 FROM T`
# one row.
#
# What the checks are built around:
#
#   * TWO aggregates in one expression (`MAX(A) - MIN(A)`) need two
#     slots, and the second is a HIDDEN one appended past the output
#     columns - so the group row is wider than the select list.
#   * A GROUPED KEY inside the expression (`DEPT_ID + SUM(SALARY)`) needs
#     a slot too, even though no output column selects it.
#   * `ORDER BY` over such a query must reach those hidden slots, which
#     is a different lookup from "find the output column of that name".
#   * `SUM(A) / COUNT(*)` is INTEGER division and truncates (650/4 = 162,
#     not 163) - the engine's dialect-3 rule, checked rather than assumed.
#
# And the companion, which the same machinery answers: `ORDER BY` a
# COMPUTED output column, by ALIAS or by ORDINAL. A computed column has
# no field of its own to sort by, so the key becomes the column's own
# expression. That refused before - correctly, while nothing evaluated
# expression sort keys, and wrongly the moment something did.
#
#   qa/serve-real-aggexpr2.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4544}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-agx-crab.fdb"
B="$D/fc-agx-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# Department 2 has ONE employee, so MAX - MIN over it is 0 - the value a
# fold that read the wrong slot is least likely to produce by accident.
# The salaries do not divide evenly by the row count, so SUM/COUNT shows
# the truncation. EMP 4 has the LOWEST salary and the HIGHEST id, so
# ordering by a computed column disagrees with the row order.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (ID INTEGER, DEPT_ID INTEGER, SALARY INTEGER,
                  AMT NUMERIC(9,2), NAME VARCHAR(6));
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 10.50, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 20.25, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 5.00,  'c');
INSERT INTO EMP VALUES (4, 3,  50, NULL,  'd');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-aggexpr2.log 2>&1 &
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

# --- 0. the controls, which must not move ------------------------------
both "a bare aggregate" "SELECT SUM(SALARY) FROM EMP"
both "a bare COUNT(*)" "SELECT COUNT(*) FROM EMP"
both "a plain grouped query" \
     "SELECT DEPT_ID, SUM(SALARY) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "an expression with NO aggregate" "SELECT SALARY + 1 FROM EMP ORDER BY ID"

# --- 1. ONE aggregate inside an expression, no GROUP BY ---------------
both "SUM plus a literal" "SELECT SUM(SALARY) + 1 FROM EMP"
both "SUM minus a literal" "SELECT SUM(SALARY) - 1 FROM EMP"
both "COUNT times a literal" "SELECT COUNT(*) * 2 FROM EMP"
both "an aggregate NEGATED" "SELECT -SUM(SALARY) FROM EMP"
both "MIN plus a literal" "SELECT MIN(SALARY) + 1 FROM EMP"
both "MAX plus a literal" "SELECT MAX(SALARY) + 1 FROM EMP"
both "AVG plus a literal" "SELECT AVG(SALARY) + 1 FROM EMP"
both "with an ALIAS" "SELECT SUM(SALARY) + 1 AS T FROM EMP"
both "over a scaled NUMERIC" "SELECT SUM(AMT) + 1 FROM EMP"
both "with a WHERE" "SELECT SUM(SALARY) + 1 FROM EMP WHERE SALARY > 60"

# --- 2. TWO aggregates in one expression (a hidden slot) --------------
both "MAX minus MIN" "SELECT MAX(SALARY) - MIN(SALARY) FROM EMP"
both "SUM plus COUNT" "SELECT SUM(SALARY) + COUNT(*) FROM EMP"
# integer division TRUNCATES: 650 / 4 is 162, not 163
both "SUM over COUNT truncates" "SELECT SUM(SALARY) / COUNT(*) FROM EMP"
both "three aggregates" \
     "SELECT MAX(SALARY) - MIN(SALARY) + COUNT(*) FROM EMP"
both "the same aggregate twice" "SELECT SUM(SALARY) + SUM(SALARY) FROM EMP"

# --- 3. an aggregate under a CONSTRUCT --------------------------------
both "a CAST over an aggregate" "SELECT CAST(SUM(SALARY) AS VARCHAR(10)) FROM EMP"
both "a CAST to a scaled numeric" \
     "SELECT CAST(SUM(SALARY) AS NUMERIC(9,2)) FROM EMP"
both "a CASE whose CONDITION is an aggregate" \
     "SELECT CASE WHEN COUNT(*) > 2 THEN 1 ELSE 0 END FROM EMP"
both "a CASE whose BRANCH is an aggregate" \
     "SELECT CASE WHEN 1 = 1 THEN SUM(SALARY) ELSE 0 END FROM EMP"
both "COALESCE over an aggregate" "SELECT COALESCE(MAX(SALARY), 0) FROM EMP"
both "IIF over an aggregate" "SELECT IIF(COUNT(*) > 2, 1, 0) FROM EMP"
both "a condition over aggregates as a VALUE" \
     "SELECT MAX(SALARY) > MIN(SALARY) FROM EMP"

# --- 4. GROUPED ------------------------------------------------------
both "grouped, aggregate in an expression" \
     "SELECT DEPT_ID, SUM(SALARY) + 1 FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
# department 2 has ONE employee, so its MAX - MIN is 0
both "grouped, two aggregates" \
     "SELECT DEPT_ID, MAX(SALARY) - MIN(SALARY) FROM EMP GROUP BY DEPT_ID
      ORDER BY DEPT_ID"
both "grouped, the KEY inside the expression" \
     "SELECT DEPT_ID + SUM(SALARY) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "grouped, key and aggregate as separate items" \
     "SELECT DEPT_ID, COUNT(*) * 10 FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "grouped with a HAVING" \
     "SELECT DEPT_ID, SUM(SALARY) + 1 FROM EMP GROUP BY DEPT_ID
      HAVING COUNT(*) > 0 ORDER BY DEPT_ID"
both "grouped, ORDER BY the key DESC" \
     "SELECT DEPT_ID, SUM(SALARY) + 1 FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID DESC"
both "grouped over a NUMERIC" \
     "SELECT DEPT_ID, SUM(AMT) + 1 FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"

# --- 5. ORDER BY a COMPUTED output column ----------------------------
# EMP 4 has the lowest salary and the highest id, so each of these puts
# it where the row order never would
both "ORDER BY an expression ALIAS" "SELECT SALARY + 1 AS S FROM EMP ORDER BY S"
both "ORDER BY an expression ORDINAL" "SELECT SALARY + 1 FROM EMP ORDER BY 1"
both "... DESCENDING" "SELECT SALARY + 1 FROM EMP ORDER BY 1 DESC"
both "ORDER BY a computed column, several items" \
     "SELECT ID, SALARY * -1 FROM EMP ORDER BY 2"
both "grouped: ORDER BY an aggregate expression's ALIAS" \
     "SELECT DEPT_ID, SUM(SALARY) + 1 AS T FROM EMP GROUP BY DEPT_ID ORDER BY T"
both "grouped: ... by its ORDINAL" \
     "SELECT DEPT_ID, SUM(SALARY) + 1 FROM EMP GROUP BY DEPT_ID ORDER BY 2"
both "a join: ORDER BY an expression ALIAS" \
     "SELECT E.SALARY + 1 AS S FROM EMP E JOIN EMP F ON E.ID = F.ID ORDER BY S"
# the plain forms must not have moved
both "ORDER BY a plain ORDINAL" "SELECT ID FROM EMP ORDER BY 1"
both "ORDER BY a plain ALIAS" "SELECT ID AS X FROM EMP ORDER BY X"
both "ORDER BY an aggregate's ordinal" \
     "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY 2 DESC"

# --- 6. the once-refused shapes, landed by the statexpr slice ---------
# DISTINCT and expression ARGUMENTS inside folded aggregates were "a
# later slice" here until aggregates-in-expressions shipped - they
# answer differentially now
both "COUNT(DISTINCT c) inside an expression (the statexpr slice)" \
     "SELECT COUNT(DISTINCT DEPT_ID) + 1 FROM EMP"
both "an EXPRESSION argument inside a folded aggregate (the statexpr slice)" \
     "SELECT SUM(SALARY + 1) + 1 FROM EMP"

rm -f "$A" "$B"
if [ "$ran" -lt 45 ]; then
    echo "DIFF only $ran checks ran (expected at least 45) - did one silently skip?"
    fail=1
fi
exit $fail
