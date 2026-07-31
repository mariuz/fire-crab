#!/bin/bash
# EXPRESSIONS, ROW MODIFIERS and EXPRESSION SORT KEYS over a JOIN -
# against the REAL engine as a twin: the same driver, the same statement,
# two servers, two identical databases.
#
# The join gained projections, WHERE, ON predicates, chains, GROUP BY and
# aggregates over several increments. What it never gained was the rest
# of the SELECT: its select list took BARE COLUMNS AND NOTHING ELSE, so
# `SELECT E.SALARY + 1 FROM ... JOIN ...` refused, and so did every CASE,
# CAST, function, COALESCE and condition-as-value. `DISTINCT`, `FIRST`,
# `SKIP` and `ROWS` refused over a join too, and `ORDER BY <expression>`
# with them.
#
# None of these are join FEATURES. Each is a capability the
# single-relation path has had for increments, which the join path never
# learned - the failure shape this project keeps meeting, and the reason
# this gate is organised by CAPABILITY rather than by join shape: every
# check here has a single-table twin that already passed.
#
# The three pieces that made it work are worth naming, because each was
# already present and merely not wired up:
#
#   * the COMBINED VIEW (a join's rows seen as one synthetic relation)
#     lets `build_expr_col` - the ordinary select-list expression builder
#     - run unchanged over a join.
#   * `branch_rows` is what materialises rows for a DISTINCT/FIRST
#     wrapper; it knew Project, Union and ProcRows, so teaching it Join
#     and JoinGroup gave INSERT ... SELECT and FOR SELECT the same
#     sources for free.
#   * `sort_rows` - the sort that EVALUATES expression keys - existed
#     with NO CALLERS. Join, JoinGroup and Group all sorted with
#     `order_cmp`, which reads a key's FIELD and ignores its expression,
#     so an expression sort key silently sorted by field 0. That is the
#     dangerous half of this increment: accepting `ORDER BY <expr>` while
#     sorting by something else is a wrong answer where the refusal was
#     merely a gap.
#
#   qa/serve-real-joinexpr.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4543}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-jexpr-crab.fdb"
B="$D/fc-jexpr-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# EMP 4's salary is the LOWEST while its id is the HIGHEST, so a sort by
# an expression over SALARY and a sort by the natural row order disagree
# - which is what tells a real expression sort from one that quietly used
# field 0. EMP 5 has no department, for the outer join's padded row.
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
COMMIT;
CREATE VIEW VEMP AS SELECT ID, DEPT_ID, SALARY, NAME FROM EMP WHERE SALARY > 60;
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-joinexpr.log 2>&1 &
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
# fire-crab against ISQL, for the shapes this driver cannot decode from
# the ENGINE (a text column of a joined table comes back as `string right
# truncation` from the engine itself, so the twin has no oracle there)
vs_isql() { # <label> <sql> <isql select body>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A" \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
             try{console.log(JSON.parse(s).map(r=>String(Object.values(r)[0]).replace(/\s+$/,"")).join("|"))}
             catch(e){console.log("PARSE_ERR")}})' 2>/dev/null)
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$B" <<EOF 2>&1 | sed 's/[[:space:]]*$//' | grep -v '^$' | paste -sd'|'
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

J="FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID"

# --- 0. the controls ---------------------------------------------------
both "a bare column over the join" "SELECT E.ID $J ORDER BY E.ID"
both "the join's row count" "SELECT COUNT(*) $J"

# --- 1. EXPRESSIONS in the select list --------------------------------
both "arithmetic" "SELECT E.SALARY + 1 $J ORDER BY E.ID"
both "arithmetic over BOTH sides" "SELECT E.SALARY + D.ID $J ORDER BY E.ID"
both "multiplication and division" "SELECT E.SALARY * 2, E.SALARY / 2 $J ORDER BY E.ID"
both "a CASE" \
     "SELECT CASE WHEN E.SALARY > 150 THEN 1 ELSE 0 END $J ORDER BY E.ID"
both "a searched CASE over both sides" \
     "SELECT CASE WHEN D.ID = 1 THEN E.SALARY ELSE 0 END $J ORDER BY E.ID"
both "a CAST" "SELECT CAST(E.SALARY AS VARCHAR(10)) $J ORDER BY E.ID"
both "a CAST to a scaled numeric" \
     "SELECT CAST(E.SALARY AS NUMERIC(9,2)) $J ORDER BY E.ID"
both "UPPER" "SELECT UPPER(E.NAME) $J ORDER BY E.ID"
both "COALESCE" "SELECT COALESCE(E.SALARY, 0) $J ORDER BY E.ID"
both "IIF" "SELECT IIF(E.SALARY > 150, 1, 0) $J ORDER BY E.ID"
both "a CONDITION as a value" "SELECT E.SALARY > 150 $J ORDER BY E.ID"
both "an expression with an ALIAS" "SELECT E.SALARY + 1 AS S $J ORDER BY E.ID"
both "columns and expressions mixed" \
     "SELECT E.ID, E.SALARY * 2, D.ID $J ORDER BY E.ID"
both "a BARE unambiguous name in an expression" \
     "SELECT SALARY + 1 $J ORDER BY E.ID"
both "an expression over an OUTER join's padded row" \
     "SELECT E.ID, COALESCE(D.ID, -1) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID
      ORDER BY E.ID"
both "a CASE over the padded side" \
     "SELECT E.ID, CASE WHEN D.ID IS NULL THEN 'none' ELSE 'some' END
      FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID"
both "an expression over a VIEW's side of a join" \
     "SELECT V.SALARY + 1 FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID ORDER BY V.ID"
# CONCATENATION is compared against ISQL: this driver cannot decode the
# ENGINE's own answer when a join projects a text column of the joined
# table (`string right truncation`), so the twin has no oracle for it
vs_isql "concatenation, against isql" \
        "SELECT E.NAME || D.DNAME $J ORDER BY E.ID" \
        "SELECT E.NAME || D.DNAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID"

# --- 2. the ROW MODIFIERS ----------------------------------------------
both "DISTINCT" "SELECT DISTINCT E.DEPT_ID $J ORDER BY E.DEPT_ID"
both "DISTINCT over an expression" "SELECT DISTINCT E.SALARY * 0 $J"
both "DISTINCT over an outer join" \
     "SELECT DISTINCT D.ID FROM DEPT D LEFT JOIN EMP E ON E.DEPT_ID = D.ID ORDER BY D.ID"
both "FIRST" "SELECT FIRST 2 E.ID $J ORDER BY E.ID"
both "SKIP" "SELECT SKIP 1 E.ID $J ORDER BY E.ID"
both "FIRST and SKIP together" "SELECT FIRST 2 SKIP 1 E.ID $J ORDER BY E.ID"
both "ROWS" "SELECT E.ID $J ORDER BY E.ID ROWS 2"
both "ROWS n TO m" "SELECT E.ID $J ORDER BY E.ID ROWS 2 TO 3"
both "FIRST over a GROUPED join" \
     "SELECT FIRST 1 D.ID, COUNT(*) $J GROUP BY D.ID ORDER BY D.ID"
both "DISTINCT over a GROUPED join" \
     "SELECT DISTINCT COUNT(*) $J GROUP BY D.ID ORDER BY 1"
both "FIRST over a join through a VIEW" \
     "SELECT FIRST 2 V.ID FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID ORDER BY V.ID"

# --- 3. ORDER BY an EXPRESSION -----------------------------------------
# EMP 4 has the LOWEST salary and the HIGHEST id, so each of these puts
# it somewhere the natural row order never would - a sort that ignored
# the expression and used field 0 answers the id order instead
both "ORDER BY arithmetic" "SELECT E.ID $J ORDER BY E.SALARY + 0"
both "ORDER BY arithmetic DESC" "SELECT E.ID $J ORDER BY E.SALARY * 1 DESC"
both "ORDER BY an expression over both sides" \
     "SELECT E.ID $J ORDER BY E.SALARY + D.ID"
both "ORDER BY a CASE" \
     "SELECT E.ID $J ORDER BY CASE WHEN E.SALARY > 150 THEN 0 ELSE 1 END, E.ID"
both "ORDER BY a function" "SELECT E.ID $J ORDER BY UPPER(E.NAME) DESC"
both "an expression key beside a column key" \
     "SELECT E.ID $J ORDER BY D.ID, E.SALARY + 0"
both "ORDER BY an expression with FIRST" \
     "SELECT FIRST 2 E.ID $J ORDER BY E.SALARY + 0"
both "ORDER BY an expression with DISTINCT" \
     "SELECT DISTINCT E.DEPT_ID $J ORDER BY E.DEPT_ID + 0"
both "a plain column key still sorts" "SELECT E.ID $J ORDER BY E.ID DESC"
both "a grouped join still sorts" \
     "SELECT D.ID, COUNT(*) $J GROUP BY D.ID ORDER BY D.ID DESC"

# --- 4. the single-relation twins, which must not have moved -----------
both "single: an expression item" "SELECT SALARY + 1 FROM EMP ORDER BY ID"
both "single: DISTINCT" "SELECT DISTINCT DEPT_ID FROM EMP ORDER BY DEPT_ID"
both "single: FIRST" "SELECT FIRST 2 ID FROM EMP ORDER BY ID"
both "single: ORDER BY an expression" "SELECT ID FROM EMP ORDER BY SALARY + 0"
both "single: a grouped ORDER BY" \
     "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID DESC"

rm -f "$A" "$B"
if [ "$ran" -lt 45 ]; then
    echo "DIFF only $ran checks ran (expected at least 45) - did one silently skip?"
    fail=1
fi
exit $fail
