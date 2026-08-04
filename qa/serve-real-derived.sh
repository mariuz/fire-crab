#!/bin/bash
# DERIVED TABLES - `SELECT ... FROM (SELECT ...) X` - against the REAL
# engine as a twin: the same driver, the same statement, two servers, two
# identical databases.
#
# This is the first shape the ROW-SOURCE TREE answers that the textual
# rewriting could not reach, and the reason is worth stating: every
# earlier "query over a query" here worked by SUBSTITUTING A NAME. A view
# has a catalog entry, a CTE has one written in the statement - so both
# could be expanded into the FROM and re-planned. A derived table has
# NEITHER. Its columns exist only because the inner query ANNOUNCES them,
# and its rows exist only because something RAN it.
#
# So the outer query resolves against a SYNTHETIC VIEW built from the
# inner plan's describe - the same move the join makes with its combined
# row and the group makes with its folded one - and the inner plan's rows
# become a materialised leaf with the outer WHERE and ORDER BY as nodes
# above it. The describe is the right source for the shape: if the outer
# query and the CLIENT disagree about a column's type, one of them is
# wrong.
#
# The checks are built around what the two sides can each contribute:
#
#   * the INNER query's own WHERE and ORDER BY, which belong to it;
#   * the OUTER query's WHERE and ORDER BY, which see only what the inner
#     one projected - a column the inner query did not select is not
#     there, and that is a REFUSAL rather than a silent NULL;
#   * a RENAMED or COMPUTED inner column, which has no relation behind it
#     at all and exists purely as an announcement.
#
# One structural fix came with it: the clause splitter found the FIRST
# `WHERE`/`GROUP BY`/`HAVING`/`ORDER BY` keyword ANYWHERE in the text,
# and a derived table puts one INSIDE parentheses. `FROM` had been found
# at paren depth 0 since `SUBSTRING(S FROM 2)`; now every clause keyword
# is. The subquery checks at the end are there because that change
# touches every statement, not only these.
#
#   qa/serve-real-derived.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4552}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-drv-crab.fdb"
B="$D/fc-drv-engine.fdb"

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
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-derived.log 2>&1 &
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

# --- 0. the control ---------------------------------------------------
both "the same query without one" "SELECT ID FROM EMP ORDER BY ID"

# --- 1. the shape itself ----------------------------------------------
both "a derived table" "SELECT X.ID FROM (SELECT ID FROM EMP) X ORDER BY X.ID"
both "the AS spelling" "SELECT X.ID FROM (SELECT ID FROM EMP) AS X ORDER BY X.ID"
both "referenced WITHOUT the qualifier" \
     "SELECT ID FROM (SELECT ID FROM EMP) X ORDER BY ID"
both "several columns" \
     "SELECT X.ID, X.SALARY FROM (SELECT ID, SALARY FROM EMP) X ORDER BY X.ID"
both "a star over one" \
     "SELECT * FROM (SELECT ID, SALARY FROM EMP WHERE ID < 3) X ORDER BY ID"
both "a text column through one" \
     "SELECT X.NAME FROM (SELECT ID, NAME FROM EMP) X WHERE X.ID = 1"

# --- 2. which side each clause belongs to -----------------------------
both "the INNER query's WHERE" \
     "SELECT X.ID FROM (SELECT ID FROM EMP WHERE SALARY > 150) X ORDER BY X.ID"
both "the OUTER query's WHERE" \
     "SELECT X.ID FROM (SELECT ID, SALARY FROM EMP) X WHERE X.SALARY > 150 ORDER BY X.ID"
both "both, and they compose" \
     "SELECT X.ID FROM (SELECT ID, SALARY FROM EMP WHERE SALARY > 60) X
      WHERE X.SALARY < 350 ORDER BY X.ID"
both "the INNER query's ORDER BY" \
     "SELECT X.ID FROM (SELECT ID FROM EMP ORDER BY ID DESC) X ORDER BY X.ID"
both "the OUTER query's ORDER BY wins the output" \
     "SELECT X.ID FROM (SELECT ID FROM EMP ORDER BY ID) X ORDER BY X.ID DESC"
both "an outer WHERE on a NULL column" \
     "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP) X WHERE X.DEPT_ID IS NULL"

# --- 3. columns that exist only as an ANNOUNCEMENT --------------------
both "a RENAMED inner column" \
     "SELECT X.N FROM (SELECT ID AS N FROM EMP) X ORDER BY X.N"
both "a COMPUTED inner column" \
     "SELECT X.S FROM (SELECT SALARY + 1 AS S FROM EMP) X ORDER BY X.S"
both "... filtered by the outer query" \
     "SELECT X.S FROM (SELECT SALARY + 1 AS S FROM EMP) X WHERE X.S > 150 ORDER BY X.S"
both "a computed column of TEXT" \
     "SELECT X.U FROM (SELECT UPPER(NAME) AS U FROM EMP) X WHERE X.U = 'A'"
both "an expression OVER a computed column" \
     "SELECT X.S * 2 FROM (SELECT SALARY + 1 AS S FROM EMP) X ORDER BY X.S"

# --- 4. what stacks on top --------------------------------------------
both "FIRST over a derived table" \
     "SELECT FIRST 2 X.ID FROM (SELECT ID FROM EMP) X ORDER BY X.ID"
both "SKIP as well" \
     "SELECT SKIP 1 X.ID FROM (SELECT ID FROM EMP) X ORDER BY X.ID"
both "DISTINCT over one" \
     "SELECT DISTINCT X.DEPT_ID FROM (SELECT DEPT_ID FROM EMP) X ORDER BY X.DEPT_ID"
both "an alias on an outer column" \
     "SELECT X.ID AS K FROM (SELECT ID FROM EMP) X ORDER BY K"
both "ORDER BY an outer expression" \
     "SELECT X.ID FROM (SELECT ID, SALARY FROM EMP) X ORDER BY X.SALARY * -1"

# --- 5. a nested derived table ----------------------------------------
both "a derived table over a derived table" \
     "SELECT Y.ID FROM (SELECT X.ID FROM (SELECT ID FROM EMP) X) Y ORDER BY Y.ID"
both "... with a filter at each level" \
     "SELECT Y.ID FROM (SELECT X.ID, X.SALARY FROM (SELECT ID, SALARY FROM EMP
      WHERE SALARY > 60) X WHERE X.SALARY < 350) Y ORDER BY Y.ID"

# --- 5a. a derived table as a SIDE OF A JOIN --------------------------
# The EXECUTION half needed nothing: `NestedLoopJoin` takes a row source
# per side and does not care where the rows come from. The PLANNING half
# is the work - a side's columns and descriptors come from the inner
# plan's describe when it is derived, rather than from a relation.
both "a derived table on the LEFT of a join" \
     "SELECT COUNT(*) FROM (SELECT ID, DEPT_ID FROM EMP) X JOIN DEPT D ON X.DEPT_ID = D.ID"
both "on the RIGHT" \
     "SELECT COUNT(*) FROM DEPT D JOIN (SELECT ID, DEPT_ID FROM EMP) X ON X.DEPT_ID = D.ID"
both "BOTH sides derived" \
     "SELECT COUNT(*) FROM (SELECT ID, DEPT_ID FROM EMP) X
      JOIN (SELECT ID FROM DEPT) Y ON X.DEPT_ID = Y.ID"
both "projecting through a derived side" \
     "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP) X JOIN DEPT D ON X.DEPT_ID = D.ID
      ORDER BY X.ID"
both "a derived side with its own WHERE" \
     "SELECT COUNT(*) FROM (SELECT ID, DEPT_ID FROM EMP WHERE SALARY > 150) X
      JOIN DEPT D ON X.DEPT_ID = D.ID"
both "a GROUPED derived side" \
     "SELECT COUNT(*) FROM (SELECT DEPT_ID, COUNT(*) AS N FROM EMP GROUP BY DEPT_ID) X
      JOIN DEPT D ON X.DEPT_ID = D.ID"
both "a derived side on the padded side of a LEFT join" \
     "SELECT COUNT(*) FROM DEPT D LEFT JOIN (SELECT DEPT_ID FROM EMP WHERE SALARY > 150) X
      ON X.DEPT_ID = D.ID"
both "GROUP BY over a join with a derived side" \
     "SELECT D.ID, COUNT(*) FROM (SELECT DEPT_ID FROM EMP) X JOIN DEPT D ON X.DEPT_ID = D.ID
      GROUP BY D.ID ORDER BY D.ID"
# the comma inside a derived table's OWN select list is that query's, not
# this FROM's - reading it as a comma-join list broke every derived side
# whose body selected more than one column
both "a comma join beside a derived table" \
     "SELECT COUNT(*) FROM EMP E, DEPT D WHERE E.DEPT_ID = D.ID"

# --- 6. the refusals, each for a stated reason ------------------------
# a column the INNER query did not project is not there to name
refuses "a column the inner query did not select" \
        "SELECT X.SALARY FROM (SELECT ID FROM EMP) X"
# The fold has to run ABOVE the leaf, which is what a grouped JOIN with
# no parts already is - so the same node serves a derived table, and
# these four refused until the two planners became one.
both "GROUP BY over a derived table" \
     "SELECT X.DEPT_ID, COUNT(*) AS K FROM (SELECT DEPT_ID FROM EMP) X
      GROUP BY X.DEPT_ID ORDER BY X.DEPT_ID"
both "a bare GROUP BY key over a derived table" \
     "SELECT DEPT_ID, COUNT(*) AS K FROM (SELECT DEPT_ID FROM EMP) X
      GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "an ungrouped aggregate over a derived table" \
     "SELECT SUM(X.SALARY) AS S FROM (SELECT SALARY FROM EMP) X"
both "GROUP BY with a HAVING over a derived table" \
     "SELECT X.DEPT_ID, MAX(X.SALARY) AS M FROM (SELECT DEPT_ID, SALARY FROM EMP) X
      GROUP BY X.DEPT_ID HAVING COUNT(*) > 1 ORDER BY X.DEPT_ID"
# SQL requires a derived table to be named; without one there is nothing
# to qualify its columns with
refuses "a derived table with NO alias" "SELECT ID FROM (SELECT ID FROM EMP)"

# --- 7. the clause splitter, which this changed for EVERY statement ---
both "a subquery in the WHERE still splits" \
     "SELECT COUNT(*) FROM EMP WHERE DEPT_ID IN (SELECT ID FROM DEPT WHERE ID > 1)"
both "a grouped query still splits" \
     "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
both "a select-list subquery still splits" \
     "SELECT ID, (SELECT COUNT(*) FROM DEPT WHERE ID > 1) FROM EMP WHERE ID = 1"
# (counted rather than projected: this driver cannot decode the ENGINE's
# answer for a lone text column, so the twin has no oracle for that shape)
both "SUBSTRING's own FROM keyword still splits" \
     "SELECT COUNT(*) FROM EMP WHERE SUBSTRING(NAME FROM 1 FOR 1) = 'a'"

# --- a materialised row source carries its rows' OWN error ------------
# branch_rows answered an Option, so "this shape is unserved" and "the
# rows RAISED" came back identically - and every caller that needed an
# error to return invented an argument-less isc_convert_error, which
# renders as the engine's UNFILLED MESSAGE TEMPLATE at the client. A
# derived table, a view and a union branch are all materialised through
# that one function, so all three said the wrong thing about the same
# raise. The row's own vector travels now; the genuinely unserved shape
# is the generic refusal, which is what it always should have been.
#
# `both` compares the whole error text, so these compare the VECTOR and
# not merely that both sides failed - the distinction that let a wrong
# error class hide in this suite for four increments.
both "a derived table whose rows raise" \
     "SELECT * FROM (SELECT ID, 10/(ID-2) AS Q FROM EMP) X"
both "a derived table raising on its FIRST row" \
     "SELECT * FROM (SELECT ID, 10/(ID-1) AS Q FROM EMP) X"
both "a union branch that raises" \
     "SELECT ID FROM EMP UNION SELECT 10/(ID-2) FROM EMP"
both "a union ALL branch that raises" \
     "SELECT ID FROM EMP UNION ALL SELECT 10/(ID-2) FROM EMP"
both "a derived table over a union that raises" \
     "SELECT * FROM (SELECT ID FROM EMP UNION SELECT 10/(ID-2) FROM EMP) X"
# and the controls: the same shapes that do NOT raise must be unmoved
both "control: a derived table that does not raise" \
     "SELECT * FROM (SELECT ID FROM EMP) X ORDER BY ID"
both "control: a union that does not raise" \
     "SELECT ID FROM EMP UNION SELECT ID + 10 FROM EMP"
both "control: a derived table with a division that succeeds" \
     "SELECT * FROM (SELECT ID, 100/ID AS Q FROM EMP) X ORDER BY ID"


# --- THE CURSOR IS LAZY: rows before the raise ------------------------
# The engine delivers the rows that PRECEDE a raiser and then raises;
# collecting the inner rows first raised before any row shipped. Probed,
# the law is finer than "materialise or not":
#
#   ORDER BY ID DESC over a raising projection  -> row 4, THEN the raise
#                                                  (the SORT materialises
#                                                   its KEY, and the
#                                                   projection is
#                                                   evaluated at DELIVERY)
#   a raiser IN THE SORT KEY, or DISTINCT       -> no rows at all
#   UNION ALL                                   -> every row of branch 1,
#                                                  then branch 2 up to its
#                                                  raiser
#
# THESE CANNOT BE CHECKED THROUGH node-firebird: it buffers the whole
# result, so a partial delivery and a clean refusal look identical to
# it. isql prints rows as they arrive, which is the only oracle here -
# so `stream` compares the WHOLE session text, rows and error together.
stream() { # <label> <sql>
    ran=$((ran + 1))
    a=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | tr -s ' \n' ' ')
    b=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | tr -s ' \n' ' ')
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$b]"; echo "     fc:     [$a]"; fail=1
    fi
}
stream "a derived table delivers the rows before its raiser" \
       "SELECT * FROM (SELECT ID, 10/(ID-3) AS Q FROM EMP) X"
stream "the same with a WHERE above it" \
       "SELECT * FROM (SELECT ID, 10/(ID-3) AS Q FROM EMP) X WHERE ID < 5"
stream "UNION ALL delivers branch 1 whole, then branch 2 up to its raiser" \
       "SELECT ID FROM EMP UNION ALL SELECT 10/(ID-3) FROM EMP"
stream "control: a derived table with no raiser" \
       "SELECT * FROM (SELECT ID, SALARY FROM EMP) X"
stream "control: a UNION ALL with no raiser" \
       "SELECT ID FROM EMP UNION ALL SELECT SALARY FROM EMP"
# THE BLOCKING SHAPES. Neither side delivers a row, which is the
# substantive half and is what `blocks` asserts. What differs is one
# blank line: the engine raises at OPEN, before isql prints anything,
# while fire-crab announces the result set and raises at the first
# FETCH - the same lazy/eager split one level up, pre-existing (the
# HEAD binary does it too) and recorded rather than folded in here.
blocks() { # <label> <sql>
    ran=$((ran + 1))
    a=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | tr -s ' \n' ' ')
    b=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | tr -s ' \n' ' ')
    # no DATA row on either side: everything before the failure is blank
    ar=$(printf '%s' "$a" | sed 's/Statement failed.*//' | tr -d ' ')
    br=$(printf '%s' "$b" | sed 's/Statement failed.*//' | tr -d ' ')
    if [ -n "$ar" ] || [ -n "$br" ]; then
        echo "DIFF $1 - a row was delivered before the raise"
        echo "     engine: [$b]"; echo "     fc:     [$a]"; fail=1
    elif [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "BOUND $1 - neither delivers a row; fire-crab announces the"
        echo "      result set first (raises at FETCH, the engine at OPEN)"
    fi
}
blocks "DISTINCT blocks - no rows before the raise" \
       "SELECT DISTINCT * FROM (SELECT ID, 10/(ID-3) AS Q FROM EMP) X"
blocks "a distinct UNION blocks" \
       "SELECT ID FROM EMP UNION SELECT 10/(ID-3) FROM EMP"

rm -f "$A" "$B"



if [ "$ran" -lt 55 ]; then
    echo "DIFF only $ran checks ran (expected at least 55) - did one silently skip?"
    fail=1
fi
exit $fail
