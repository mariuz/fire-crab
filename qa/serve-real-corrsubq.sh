#!/bin/bash
# A CORRELATED scalar subquery in the SELECT LIST - `SELECT D.ID,
# (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) FROM DEPT D` -
# against the REAL engine as a twin: the same driver, the same statement,
# two servers, two identical databases.
#
# The previous increment folded a CONSTANT subquery into the query text
# as the literal it computed, and REFUSED a correlated one - rightly,
# since a correlated subquery has no single value to fold: it has one per
# outer row.
#
# So it is not folded. It is precomputed as a LOOKUP TABLE: the inner
# table is scanned ONCE at prepare, its rows bucketed by the correlation
# column, each bucket folded into the one value the subquery answers for
# that key. Each outer row then looks its own key up. A correlated
# aggregate IS a group - keyed by the correlation column - so the fold is
# the same `compute_group` a GROUP BY runs.
#
# THE LAW THIS GATE EXISTS FOR: a key with NO matching inner rows is NOT
# always NULL. `COUNT` answers 0 there and every other function answers
# NULL - probed, and visible in ONE ROW of the fixture:
#
#     SELECT D.ID,
#            (SELECT COUNT(*)      FROM EMP E WHERE E.DEPT_ID = D.ID),
#            (SELECT MAX(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID)
#       FROM DEPT D
#
#   department 9 has no employees and answers 0 and <null> in the SAME
#   ROW. A lookup table that defaulted to NULL is right for three of the
#   four functions and wrong for the one people use most.
#
# The other traps the checks are built around:
#
#   * The inner table's ALIAS is its qualifier. `FROM EMP E ... WHERE
#     E.DEPT_ID = D.ID` correlates through E, and reading only the table
#     NAME finds no correlation at all - every aliased correlated
#     subquery refused, which is nearly all of them as people write them.
#   * `SUM(E.SALARY)` parses as an EXPRESSION target, not a column one -
#     the dot stops it looking like an identifier - so the qualified
#     spelling took a different path from `SUM(SALARY)` and refused while
#     the bare one worked.
#   * A NULL outer key matches nothing (`NULL = NULL` is UNKNOWN), so it
#     takes the absent answer rather than a bucket.
#   * The outer table's qualifiers are stripped INSIDE this planner and
#     not by the general pass, which would also strip them inside the
#     SUBQUERY - where a bare `ID` would resolve against the INNER table
#     and silently change which column the correlation names.
#
#   qa/serve-real-corrsubq.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4546}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-csq-crab.fdb"
B="$D/fc-csq-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# DEPT 9 has NO employees - the row where COUNT and MAX disagree about
# what "no rows" means. EMP 5 has a NULL department, so a lookup keyed
# the other way has a NULL key that must match nothing.
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

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-corrsubq.log 2>&1 &
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

C="FROM DEPT D ORDER BY D.ID"

# --- 0. the controls ---------------------------------------------------
both "a plain select" "SELECT D.ID $C"
both "a CONSTANT subquery, as before" "SELECT D.ID, (SELECT COUNT(*) FROM EMP) $C"

# --- 1. the per-key fold, and what an EMPTY key answers ----------------
both "COUNT, which is 0 for an empty key" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
both "MAX, which is NULL for an empty key" \
     "SELECT D.ID, (SELECT MAX(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
# the two in ONE ROW - the check the whole design turns on
both "COUNT and MAX side by side" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) AS N,
             (SELECT MAX(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) AS M $C"
both "MIN" "SELECT D.ID, (SELECT MIN(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
both "SUM" "SELECT D.ID, (SELECT SUM(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
both "AVG" "SELECT D.ID, (SELECT AVG(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"

# --- 2. how the correlation may be SPELLED ----------------------------
both "the inner table by its ALIAS" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
both "the inner table UNALIASED" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP WHERE DEPT_ID = D.ID) $C"
both "the equality REVERSED" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE D.ID = E.DEPT_ID) $C"
both "the OUTER table unaliased" \
     "SELECT DEPT.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = DEPT.ID)
      FROM DEPT ORDER BY DEPT.ID"
both "a QUALIFIED aggregate target" \
     "SELECT D.ID, (SELECT MAX(E.SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
both "an UNQUALIFIED aggregate target" \
     "SELECT D.ID, (SELECT MAX(SALARY) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"

# --- 3. the subquery's own filter, beside the correlation -------------
both "a residual inner filter" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID AND E.SALARY > 150) $C"
both "two residual terms" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E
                     WHERE E.DEPT_ID = D.ID AND E.SALARY > 60 AND E.SALARY < 350) $C"
both "a residual that empties every bucket" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID AND E.SALARY > 9999) $C"

# --- 4. a NULL key matches nothing ------------------------------------
# keyed the other way: EMP 5 has a NULL department
both "a NULL outer key takes the absent answer" \
     "SELECT E.ID, (SELECT COUNT(*) FROM DEPT D WHERE D.ID = E.DEPT_ID)
      FROM EMP E ORDER BY E.ID"
both "... and with MAX beside it" \
     "SELECT E.ID, (SELECT MAX(D.ID) FROM DEPT D WHERE D.ID = E.DEPT_ID)
      FROM EMP E ORDER BY E.ID"

# --- 5. what the looked-up value flows into ---------------------------
both "with an ALIAS" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) AS N $C"
both "as the ONLY item" \
     "SELECT (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) $C"
both "beside two other columns" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID), D.ID + 1 $C"
both "with an outer WHERE" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID)
      FROM DEPT D WHERE D.ID < 3 ORDER BY D.ID"
both "ORDER BY the looked-up column" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID) AS N
      FROM DEPT D ORDER BY N, D.ID"
both "ORDER BY an outer expression" \
     "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID)
      FROM DEPT D ORDER BY D.ID * -1"

# --- 6. the refusals, each for a stated reason ------------------------
# a NON-EQUALITY correlation cannot be a keyed table: the engine answers
# it by re-running the subquery per row, which this fold does not do
refuses "a NON-EQUALITY correlation" \
        "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.SALARY > D.ID * 100) FROM DEPT D"
# an inner GROUP BY would need a second level of folding
refuses "a GROUP BY inside the subquery" \
        "SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID GROUP BY E.ID)
         FROM DEPT D"

rm -f "$A" "$B"
if [ "$ran" -lt 26 ]; then
    echo "DIFF only $ran checks ran (expected at least 26) - did one silently skip?"
    fail=1
fi
exit $fail
