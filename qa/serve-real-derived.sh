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
-- columns literally NAMED after the engine's expression kind-names, which
-- is what keeps the unnamed-column test honest: it must refuse an
-- expression called ADD and ANSWER a real column called "ADD"
CREATE TABLE KK ("ADD" INTEGER, "COUNT" INTEGER);
CREATE SEQUENCE G1;
COMMIT;
-- an EXPRESSION view column: it has a name of its own and a relation
-- behind it, so a derived table over it is legal
CREATE VIEW VE AS SELECT ID, SALARY + 1 AS S FROM EMP;
COMMIT;
INSERT INTO KK VALUES (7, 8);
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
# THE PARAMETERIZED TWINS. `query`/`both` above bind nothing - this
# gate predated bound parameters in a derived body - so a `?` inside one
# needs its own helper that ships the argument message.
queryq() { # <sql> <json args> <port> <db>
    FC_Q="$1" FC_A="$2" FC_PORT="$3" FC_DB="$4" node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_A),(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
bothq() { # <label> <sql> <json args>
    ran=$((ran + 1))
    a=$(queryq "$2" "$3" "$PORT" "$A")
    b=$(queryq "$2" "$3" "$REAL" "$B")
    # A SIDE THAT DID NOT ANSWER IS NOT AGREEMENT. Two CONN_ERRs compare
    # equal and score OK while measuring nothing - which is exactly what
    # happened when these cells sat below the blocking sections.
    if [ "$a" = "CONN_ERR" ] || [ "$b" = "CONN_ERR" ] || [ -z "$a" ] || [ -z "$b" ]; then
        echo "DIFF $1 $3 [VACUOUS: a side did not answer] fcwire=[$a] engine=[$b]"
        fail=1
        return
    fi
    if [ "$a" = "$b" ]; then
        echo "OK   $1 $3: $a"
    else
        echo "DIFF $1 $3"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
# a recorded refusal that carries the ENGINE's answer, so it EXPIRES
# ITSELF the day fire-crab answers it
refusesq() { # <label> <sql> <json args>
    ran=$((ran + 1))
    a=$(queryq "$2" "$3" "$PORT" "$A")
    if [ "$a" = "CONN_ERR" ] || [ -z "$a" ]; then
        echo "DIFF $1 [VACUOUS: fcwire did not answer at all]"
        fail=1
        return
    fi
    case "$a" in
        ERR*) echo "OK   refusal kept (engine answers): $1" ;;
        *) b=$(queryq "$2" "$3" "$REAL" "$B")
           if [ "$a" = "$b" ]; then
               echo "OK   $1 now agrees: $a (update the refusal list)"
           else
               echo "DIFF $1: fcwire [$a] engine [$b]"; fail=1
           fi ;;
    esac
}

refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refused: $1" ;;
        *) echo "DIFF $1 answered: [$r]"; fail=1 ;;
    esac
}

# THE WHOLE MESSAGE, NOT ITS FIRST FIFTY CHARACTERS. `query` above keeps
# `message.split("\n")[0].slice(0,50)`, which for every -104 is the
# string "Dynamic SQL Error" on BOTH sides - so a cell built on it would
# score OK whatever column number and whatever derived-table alias the
# server named, and would only ever catch a contentless refusal. The law
# below IS the message, so it is compared whole.
qfull() { # <sql> <port> <db>
    timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("RAISE "+JSON.stringify((e2.message||"").replace(/\s+/g," ").trim()));
                 db.detach();process.exit(0);}
          console.log("ROWS "+JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
# both sides must raise, and raise THE SAME TEXT - position and alias
raises() { # <label> <sql>
    ran=$((ran + 1))
    a=$(qfull "$2" "$PORT" "$A")
    b=$(qfull "$2" "$REAL" "$B")
    case "$a$b" in
        *CONN_ERR*|"") echo "DIFF $1 [VACUOUS: a side did not answer] fcwire=[$a] engine=[$b]"
                       fail=1; return ;;
    esac
    # if the ENGINE stopped raising, the cell is describing a law that no
    # longer exists - that is a finding, not a pass
    case "$b" in
        RAISE*) ;;
        *) echo "DIFF $1 [the ENGINE did not raise: $b]"; fail=1; return ;;
    esac
    if [ "$a" = "$b" ]; then
        echo "OK   raises alike: $1 - ${b#RAISE }"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
# A RECORDED NARROWER REFUSAL. Two callers destructure the join plan for
# `Plan::Join` and drop anything else - [plan_lateral] and the lone
# COUNT(*) fast path - so the side's diagnosis becomes a bare 42000
# there. Both still REFUSE, so no wrong answer is served; the cell
# announces its own retirement the day the full message arrives.
narrower() { # <label> <sql>
    ran=$((ran + 1))
    a=$(qfull "$2" "$PORT" "$A")
    b=$(qfull "$2" "$REAL" "$B")
    case "$a$b" in
        *CONN_ERR*|"") echo "DIFF $1 [VACUOUS: a side did not answer] fcwire=[$a] engine=[$b]"
                       fail=1; return ;;
    esac
    case "$b" in
        RAISE*) ;;
        *) echo "DIFF $1 [the ENGINE did not raise: $b]"; fail=1; return ;;
    esac
    case "$a" in
        RAISE*) if [ "$a" = "$b" ]; then
                    echo "OK   $1 NOW CARRIES the engine's message - retire this record"
                else
                    echo "OK   narrower refusal recorded: $1"
                fi ;;
        *) echo "DIFF $1 ANSWERED where the engine raises: $a"; fail=1 ;;
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

# --- 5b. EVERY COLUMN MUST HAVE A NAME OF ITS OWN ---------------------
# A derived table's columns exist only because the inner query ANNOUNCES
# them, and an announcement is not a name. Three things give a column a
# name - a plain field reference (it keeps the column's own), an explicit
# AS, or the derived table's declared column list - and an unaliased
# EXPRESSION has none of them. The engine refuses the whole statement
# with -104 / "Invalid command" / "no column name specified for column
# number @1 in derived table @2"; this server used to ANSWER, inventing a
# name from the node kind.
#
# Those kind-names (ADD, UPPER, CONSTANT, COUNT, CAST, CASE, BOOL) are
# the ENGINE'S OWN - it announces them too - which is exactly why they
# cannot stand in for a name, and why the KK fixture has real columns
# CALLED "ADD" and "COUNT": the test must refuse the expression and
# answer the column.
raises "an unnamed arithmetic column"    "SELECT * FROM (SELECT SALARY + 1 FROM EMP) Z"
raises "an unnamed literal"              "SELECT * FROM (SELECT 7 FROM EMP) Z"
raises "an unnamed function"             "SELECT * FROM (SELECT UPPER(NAME) FROM EMP) Z"
raises "an unnamed scalar subquery"      "SELECT * FROM (SELECT (SELECT MAX(ID) FROM EMP) FROM EMP) Z"
raises "an unnamed CAST"                 "SELECT * FROM (SELECT CAST(ID AS BIGINT) FROM EMP) Z"
raises "an unnamed CASE"                 "SELECT * FROM (SELECT CASE WHEN ID > 2 THEN 1 ELSE 0 END FROM EMP) Z"
raises "an unnamed concatenation"        "SELECT * FROM (SELECT NAME || NAME FROM EMP) Z"
# the POSITION is the offender's, 1-based, and TWO of them report the FIRST
raises "the offender at position 2"      "SELECT * FROM (SELECT ID, SALARY + 1 FROM EMP) Z"
raises "the offender at position 3"      "SELECT * FROM (SELECT ID, DEPT_ID, SALARY + 1 FROM EMP) Z"
raises "two unnamed, the FIRST reported" "SELECT * FROM (SELECT SALARY + 1, ID + 1 FROM EMP) Z"
# an AGGREGATE or a UNION inner query plans as a fold, not a projection,
# and its columns are SLOT READS carrying no expression at all - the
# shapes a test keyed on "is there an expression here" walks straight past
raises "an unnamed aggregate"            "SELECT * FROM (SELECT COUNT(*) FROM EMP) Z"
raises "an unnamed SUM"                  "SELECT * FROM (SELECT SUM(SALARY) FROM EMP) Z"
raises "GROUP BY, the offender at 2"     "SELECT * FROM (SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID) Z"
raises "a UNION of expressions"          "SELECT * FROM (SELECT 1+1 FROM EMP UNION ALL SELECT 2+2 FROM EMP) Z"
raises "a UNION named in the SECOND only" "SELECT * FROM (SELECT 1+1 FROM EMP UNION ALL SELECT 2+2 AS E FROM EMP) Z"
# a generator and a context variable carry a kind-name and no relation
raises "NEXT VALUE FOR, unnamed"         "SELECT * FROM (SELECT NEXT VALUE FOR G1 FROM EMP) Z"
raises "GEN_ID, unnamed"                 "SELECT * FROM (SELECT GEN_ID(G1, 1) FROM EMP) Z"
raises "CURRENT_TIMESTAMP, unnamed"      "SELECT * FROM (SELECT CURRENT_TIMESTAMP FROM EMP) Z"
raises "CURRENT_USER, unnamed"           "SELECT * FROM (SELECT CURRENT_USER FROM EMP) Z"
# @2 is the scope AS WRITTEN - a CTE's name, a long alias, and for a
# nested pair the INNERMOST one, which only arrives if the inner raise is
# CARRIED rather than downgraded on its way out
raises "a CTE names the CTE"             "WITH C AS (SELECT 1+1 FROM EMP) SELECT * FROM C"
raises "a longer alias"                  "SELECT * FROM (SELECT 1+1 FROM EMP) LONGNAME"
raises "NESTED names the INNER scope"    "SELECT * FROM (SELECT * FROM (SELECT 1+1 FROM EMP) Y) Z"
# ...and the same law on a derived table used as a JOIN SIDE, which never
# reaches the plain-FROM check at all
raises "an INNER JOIN side"              "SELECT * FROM EMP A JOIN (SELECT 1+1 FROM EMP) Z ON 1=1"
raises "a LEFT JOIN side"                "SELECT * FROM EMP A LEFT JOIN (SELECT 1+1 FROM EMP) Z ON 1=1"
raises "a comma join side"               "SELECT * FROM EMP A, (SELECT 1+1 FROM EMP) Z"
raises "a side SECOND of three"          "SELECT * FROM EMP A JOIN (SELECT 1+1 FROM EMP) Z ON 1=1 JOIN EMP B ON 1=1"
raises "COUNT(*) + GROUP BY over a side" "SELECT COUNT(*) FROM EMP A JOIN (SELECT 1+1 FROM EMP) Z ON 1=1 GROUP BY A.ID"
# the OUTER query naming only the good column does not rescue it: the
# derived table is refused when it is BUILT, not when it is read
raises "the outer names the good column" "SELECT Z.ID FROM (SELECT ID, 1+1 FROM EMP) Z"

# RECORDED, both still refusing: two callers destructure for `Plan::Join`
# and drop the carried diagnosis, so these refuse WITHOUT the message
narrower "a LATERAL side"                "SELECT * FROM EMP A, LATERAL (SELECT 1+1 FROM EMP) Z"
narrower "a correlated LATERAL side"     "SELECT * FROM EMP A, LATERAL (SELECT A.ID + 1 FROM RDB\$DATABASE) Z"
narrower "lone COUNT(*) over a side"     "SELECT COUNT(*) FROM EMP A JOIN (SELECT 1+1 FROM EMP) Z ON 1=1"

# --- 5c. ...and what a NAME actually is, which must keep answering ----
both "an ALIASED expression"             "SELECT * FROM (SELECT SALARY + 1 AS S FROM EMP) Z ORDER BY 1"
both "a DECLARED column list"            "SELECT * FROM (SELECT SALARY + 1 FROM EMP) Z (S) ORDER BY 1"
both "the TOP LEVEL needs no name"       "SELECT 1+1 FROM RDB\$DATABASE"
both "a plain column, two deep"          "SELECT * FROM (SELECT * FROM (SELECT ID FROM EMP) Y) Z ORDER BY 1"
both "a UNION of COLUMNS"                "SELECT * FROM (SELECT ID FROM EMP UNION ALL SELECT DEPT_ID FROM EMP) Z ORDER BY 1"
both "a UNION named in the FIRST branch" "SELECT * FROM (SELECT 1+1 AS E FROM EMP UNION ALL SELECT 2+2 FROM EMP) Z ORDER BY 1"
both "COUNT(*) AS K"                     "SELECT * FROM (SELECT COUNT(*) AS K FROM EMP) Z"
both "SUM(SALARY) AS S"                  "SELECT * FROM (SELECT SUM(SALARY) AS S FROM EMP) Z"
both "a column literally named ADD"      "SELECT * FROM (SELECT \"ADD\" FROM KK) Z"
both "a column literally named COUNT"    "SELECT * FROM (SELECT \"COUNT\" FROM KK) Z"
both "an expression VIEW column"         "SELECT * FROM (SELECT S FROM VE) Z ORDER BY 1"
both "the whole expression view"         "SELECT * FROM (SELECT * FROM VE) Z ORDER BY 1"
both "DISTINCT over a column"            "SELECT * FROM (SELECT DISTINCT DEPT_ID FROM EMP) Z ORDER BY 1"
both "FIRST over a column"               "SELECT * FROM (SELECT FIRST 2 ID FROM EMP ORDER BY ID) Z"
both "a star over a table"               "SELECT * FROM (SELECT * FROM EMP) Z ORDER BY ID"
both "an ALIASED JOIN side"              "SELECT COUNT(*) FROM EMP A JOIN (SELECT 1+1 AS E FROM EMP) Z ON 1=1"
both "a DECLARED list on a JOIN side"    "SELECT COUNT(*) FROM EMP A JOIN (SELECT 1+1 FROM EMP) Z (E) ON 1=1"
both "an aliased LATERAL side"           "SELECT * FROM EMP A, LATERAL (SELECT A.ID + 1 AS E FROM RDB\$DATABASE) Z ORDER BY A.ID"
# RECORDED, pre-existing and unrelated to naming: an AGGREGATE over a
# LATERAL refuses here where the engine answers. Measured on BOTH this
# binary and 7a66881, so this chunk neither caused nor fixed it; the cell
# is here so it cannot be re-discovered as if it were new, and it turns
# red the day fire-crab answers it.
refuses "COUNT(*) over a LATERAL (engine answers)" \
        "SELECT COUNT(*) FROM EMP A, LATERAL (SELECT A.ID + 1 AS E FROM RDB\$DATABASE) Z"

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

# NOTE: these live ABOVE the blocking sections below. fcwire serves
# connections SERIALLY, so the cells that deliberately block leave
# nothing able to attach after them - a cell placed below answered
# CONN_ERR on BOTH sides and scored a vacuous OK.
# --- a ? INSIDE the derived body --------------------------------------
# It used to refuse outright: the inner query was planned into a FRESH
# sink and any slot it claimed killed the statement ("a `?` inside a
# derived table"). That took ORDINARY SQL with it - there is no procedure
# anywhere in `SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) X`.
# The inner now plans into the STATEMENT's sink at its text-position
# base, so slots number left to right across the nesting.
#
# Every predicate is paired with a twin that must answer NOTHING.
bothq "an inner WHERE ?" "SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[3]'
bothq "...an inner WHERE ? that EXCLUDES" "SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[99]'
bothq "an inner ? and an outer ?" "SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) X WHERE ID < ? ORDER BY ID" '[1,4]'
bothq "...the OUTER half excludes" "SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) X WHERE ID < ? ORDER BY ID" '[1,2]'
bothq "...the INNER half excludes" "SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) X WHERE ID < ? ORDER BY ID" '[99,4]'
bothq "a NESTED derived table's ?" "SELECT ID FROM (SELECT ID FROM (SELECT ID FROM EMP WHERE ID > ?) E) X ORDER BY ID" '[3]'
bothq "a CTE body's ?" "WITH C AS (SELECT ID FROM EMP WHERE ID > ?) SELECT ID FROM C ORDER BY ID" '[3]'
bothq "a CTE body's ? and an outer ?" "WITH C AS (SELECT ID FROM EMP WHERE ID > ?) SELECT ID FROM C WHERE ID < ? ORDER BY ID" '[1,4]'
bothq "an inner ? over a TEXT column" "SELECT NAME FROM (SELECT NAME FROM EMP WHERE NAME > ?) X ORDER BY NAME" '["c"]'
# AN OUTER PROJECTION `?` ABOVE AN INNER ONE - two slots, the
# PROJECTION's first (measured). These two cells would SWAP if the
# projection were numbered after the derived body's slots, which is
# exactly what used to happen and what made this refuse.
bothq "an outer projection ? above an inner ?" "SELECT CAST(? AS INTEGER) AS C, ID FROM (SELECT ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[42,3]'
bothq "...the inner half EXCLUDES" "SELECT CAST(? AS INTEGER) AS C, ID FROM (SELECT ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[42,99]'
# A FOLD ABOVE AN INNER `?`. These failed at the FETCH, not at prepare:
# the fold bound its own filter/having/parts with the arguments and then
# read its BASE row source without them. The empty-inner twins are the
# teeth AND the type check - SUM over no rows is NULL where COUNT is 0.
bothq "COUNT above an inner ?" "SELECT COUNT(*) AS N FROM (SELECT ID FROM EMP WHERE ID > ?) X" '[3]'
bothq "...COUNT over an EMPTY inner is 0" "SELECT COUNT(*) AS N FROM (SELECT ID FROM EMP WHERE ID > ?) X" '[99]'
bothq "SUM above an inner ?" "SELECT SUM(ID) AS S FROM (SELECT ID FROM EMP WHERE ID > ?) X" '[3]'
bothq "...SUM over an EMPTY inner is NULL" "SELECT SUM(ID) AS S FROM (SELECT ID FROM EMP WHERE ID > ?) X" '[99]'
bothq "MAX above an inner ?" "SELECT MAX(ID) AS M FROM (SELECT ID FROM EMP WHERE ID > ?) X" '[3]'
bothq "AVG above an inner ?" "SELECT AVG(SALARY) AS A FROM (SELECT SALARY FROM EMP WHERE SALARY > ?) X" '[100]'
bothq "a GROUP BY above an inner ?" "SELECT DEPT_ID, COUNT(*) AS N FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X GROUP BY DEPT_ID ORDER BY DEPT_ID" '[1]'
bothq "...the GROUP BY over an EMPTY inner" "SELECT DEPT_ID, COUNT(*) AS N FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X GROUP BY DEPT_ID ORDER BY DEPT_ID" '[99]'
bothq "a HAVING above an inner ?" "SELECT DEPT_ID, COUNT(*) AS N FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X GROUP BY DEPT_ID HAVING COUNT(*) > ?" '[0,1]'
bothq "...the HAVING half EXCLUDES" "SELECT DEPT_ID, COUNT(*) AS N FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X GROUP BY DEPT_ID HAVING COUNT(*) > ?" '[0,9]'
bothq "a CTE body's ? under a fold" "WITH C AS (SELECT ID FROM EMP WHERE ID > ?) SELECT COUNT(*) AS N FROM C" '[3]'
# a UNION branch carrying a `?` - the derived end of it, since a branch
# may itself be a derived table (serve-real-union owns the rest)
bothq "a ? in a UNION branch" "SELECT ID FROM EMP WHERE ID > ? UNION ALL SELECT 99 FROM RDB\$DATABASE ORDER BY 1" '[3]'
bothq "...a derived table inside that branch" "SELECT X.ID FROM (SELECT ID FROM EMP WHERE ID > ?) X UNION ALL SELECT 99 FROM RDB\$DATABASE ORDER BY 1" '[3]'
bothq "...the branch EXCLUDES everything" "SELECT X.ID FROM (SELECT ID FROM EMP WHERE ID > ?) X UNION ALL SELECT 99 FROM RDB\$DATABASE ORDER BY 1" '[99]'
# a `?` in the INNER SELECT LIST - the derived end of it
bothq "a ? in the inner projection" "SELECT C FROM (SELECT CAST(? AS INTEGER) AS C FROM EMP WHERE ID = 1) X" '[5]'
bothq "...beside a real column, inner WHERE ?" "SELECT C, ID FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[42,3]'
bothq "...the inner WHERE EXCLUDES" "SELECT C, ID FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[42,99]'
# ...and the same `?` under a FOLD or on a JOIN SIDE, where the rows come
# from a row source rather than a plan field
bothq "a FOLD over an inner projection ?" "SELECT SUM(C) AS S FROM (SELECT CAST(? AS INTEGER) AS C FROM EMP) X" '[10]'
bothq "...a GROUP BY over one" "SELECT C, COUNT(*) AS N FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM EMP) X GROUP BY C" '[10]'
bothq "a JOIN SIDE with an inner projection ?" "SELECT X.C FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM EMP WHERE ID = 1) X JOIN DEPT D ON D.ID = X.ID" '[5]'
bothq "...the side EXCLUDES every row" "SELECT X.C FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.ID" '[5,99]'
# a grouped JOIN over real tables still streams its own way - the walk
# materialises a bound DERIVED base only, and this says so
both "CONTROL a grouped join over tables" "SELECT D.DNAME, COUNT(*) AS N FROM EMP E JOIN DEPT D ON D.ID = E.DEPT_ID GROUP BY D.DNAME ORDER BY D.DNAME"
bothq "CONTROL FIRST n over a derived ?" "SELECT FIRST 2 ID FROM (SELECT ID FROM EMP WHERE ID > ?) X ORDER BY ID" '[1]'

# --- a ? inside a derived SIDE OF A JOIN -------------------------------
# The side used to be planned into a FRESH sink and refused if it claimed
# anything. Sides are built in FROM order and every ON is numbered after
# the last of them, so a side numbers from what has been claimed so far -
# the same floor the ON and the WHERE already use.
bothq "a derived side on the LEFT" "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.ID" '[1]'
bothq "...the LEFT side EXCLUDES" "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.ID" '[99]'
bothq "a derived side on the RIGHT" "SELECT X.ID FROM DEPT D JOIN (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X ON D.ID = X.DEPT_ID ORDER BY X.ID" '[1]'
bothq "TWO derived sides, one ? each" "SELECT A.ID FROM (SELECT ID FROM EMP WHERE ID > ?) A JOIN (SELECT ID FROM EMP WHERE ID < ?) B ON A.ID = B.ID ORDER BY A.ID" '[1,5]'
bothq "...the SECOND side EXCLUDES" "SELECT A.ID FROM (SELECT ID FROM EMP WHERE ID > ?) A JOIN (SELECT ID FROM EMP WHERE ID < ?) B ON A.ID = B.ID ORDER BY A.ID" '[1,2]'
bothq "a side ? then an ON ?" "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID AND D.ID > ? ORDER BY X.ID" '[1,0]'
bothq "a side ? then an outer WHERE ?" "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID WHERE X.ID < ? ORDER BY X.ID" '[1,4]'
bothq "a LEFT JOIN whose RIGHT side is derived" "SELECT D.ID, X.ID FROM DEPT D LEFT JOIN (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X ON D.ID = X.DEPT_ID ORDER BY D.ID" '[3]'
bothq "a fold over the whole join" "SELECT COUNT(*) AS N FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID" '[1]'
# ...and the WRAPPERS, which hid the join from the walk that materialises
# a bound side: without them `FIRST 2` failed where the same statement
# without it answered.
bothq "FIRST n over a join with a bound side" "SELECT FIRST 2 X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.ID" '[0]'
bothq "...FIRST n where the side EXCLUDES" "SELECT FIRST 2 X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.ID" '[99]'
bothq "SKIP over a join with a bound side" "SELECT SKIP 1 X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.ID" '[0]'
bothq "DISTINCT over a join with a bound side" "SELECT DISTINCT X.DEPT_ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.DEPT_ID" '[0]'
bothq "a derived table ABOVE the join" "SELECT Y.ID FROM (SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > ?) X JOIN DEPT D ON D.ID = X.DEPT_ID) Y ORDER BY Y.ID" '[1]'
# the controls: a join of plain tables, and an ON ? with no derived side
both "CONTROL a join of plain tables" "SELECT E.ID FROM EMP E JOIN DEPT D ON D.ID = E.DEPT_ID ORDER BY E.ID"
bothq "CONTROL an ON ? with no derived side" "SELECT E.ID FROM EMP E JOIN DEPT D ON D.ID = E.DEPT_ID AND D.ID > ? ORDER BY E.ID" '[0]'
# --- a MULTI-ON chain that IS numberable -------------------------------
# The guard used to refuse every chain of more than one join whose ON
# carried a `?`. Text order is `s0, s1, on0, s2, on1, ...` and this
# planner numbers sides then ONs, so the two agree whenever the derived
# side comes BEFORE the ONs - which is every shape here. Each cell has a
# twin that must answer NOTHING, so a mis-numbered slot cannot hide.
bothq "a derived side, then two bound ONs" "SELECT A.ID FROM EMP A JOIN (SELECT ID FROM EMP WHERE ID > ?) B ON A.ID = B.ID AND A.ID > ? JOIN DEPT D ON D.ID = A.DEPT_ID AND D.ID > ? ORDER BY A.ID" '[0,0,0]'
bothq "...the LAST ON excludes" "SELECT A.ID FROM EMP A JOIN (SELECT ID FROM EMP WHERE ID > ?) B ON A.ID = B.ID AND A.ID > ? JOIN DEPT D ON D.ID = A.DEPT_ID AND D.ID > ? ORDER BY A.ID" '[0,0,99]'
bothq "...the DERIVED SIDE excludes" "SELECT A.ID FROM EMP A JOIN (SELECT ID FROM EMP WHERE ID > ?) B ON A.ID = B.ID AND A.ID > ? JOIN DEPT D ON D.ID = A.DEPT_ID AND D.ID > ? ORDER BY A.ID" '[99,0,0]'
bothq "a ? in the FIRST ON only" "SELECT A.ID FROM EMP A JOIN (SELECT ID FROM EMP WHERE ID > ?) B ON A.ID = B.ID AND A.ID > ? JOIN DEPT D ON D.ID = A.DEPT_ID ORDER BY A.ID" '[0,0]'
bothq "a ? in the SECOND ON only" "SELECT A.ID FROM EMP A JOIN (SELECT ID FROM EMP WHERE ID > ?) B ON A.ID = B.ID JOIN DEPT D ON D.ID = A.DEPT_ID AND D.ID > ? ORDER BY A.ID" '[0,0]'
bothq "TWO derived sides ahead of two ONs" "SELECT A.ID FROM (SELECT ID FROM EMP WHERE ID > ?) A JOIN (SELECT ID FROM EMP WHERE ID < ?) B ON A.ID = B.ID AND A.ID > ? JOIN DEPT D ON D.ID = A.ID AND D.ID > ? ORDER BY A.ID" '[0,9,0,0]'
# ...but NOT with a JOIN or a FOLD above it - both still refuse, and the
# gate found that: they were written as live cells on the strength of a
# hand-probe that never covered them. Recorded rather than dropped, so
# each carries the engine's answer and expires itself.
# the LITERAL-argument twins of both shapes answer, which is what says
# only the BOUND half is missing rather than the shape itself
both "a JOIN above a LITERAL inner predicate" "SELECT X.ID FROM (SELECT ID, DEPT_ID FROM EMP WHERE ID > 1) X JOIN DEPT D ON D.ID = X.DEPT_ID ORDER BY X.ID"
both "an aggregate over a LITERAL inner predicate" "SELECT COUNT(*) AS N FROM (SELECT ID FROM EMP WHERE ID > 3) X"
# the controls: these worked BEFORE, so they say the cells above measure
# the inner-? path specifically
bothq "CONTROL an outer ? only" "SELECT ID FROM (SELECT ID FROM EMP) X WHERE ID > ? ORDER BY ID" '[3]'
both "CONTROL a literal inner predicate" "SELECT ID FROM (SELECT ID FROM EMP WHERE ID > 3) X ORDER BY ID"

# AN OUTER PROJECTION `?` ABOVE AN INNER ONE now answers, and its two
# cells are above. The projection is textually FIRST, so it numbers from
# ZERO and what the FROM claimed is a FLOOR under the WHERE - not a base
# under the projection, which is what plan_over_source used to infer from
# `params.len()`.
#
# RECORDED, NOT FIXED - each carries the engine's answer and expires
# itself. All are law-safe: refusals or fetch-time errors, never wrong
# answers.
#   (a FOLD over an inner projection `?` and a JOIN SIDE carrying one
#   were recorded here too, and are FIXED: their rows live in a
#   `RowSource::PlanRows`, which bind_plan_params never walked, so the
#   row-source walk binds that plan's projection before materialising it.
#   Cells for both are live above, and serve-real-castparamderived owns
#   the rest.)
#   - a derived side written AFTER an ON that carries its own `?`. Slots
#     number by TEXT POSITION (`s0, s1, on0, s2, on1, ...`) while this
#     planner numbers every SIDE and then every ON, so those two orders
#     agree UNLESS a side at index >= 2 claims a slot with an earlier ON
#     claiming one too - the single arrangement that would SWAP two
#     slots. Refused deliberately (multi_on_param), now testing exactly
#     that shape rather than every multi-ON chain alike.
#   (a `?` in a UNION BRANCH was recorded here too, and is FIXED: it was
#   never about derived tables - plan_union cleared the parameter sink
#   after building its branches. serve-real-union owns those cells now.)
#   (an AGGREGATE or GROUP BY above an inner `?` used to be recorded here
#   too. It was a FETCH-time failure, not a refusal - the fold read its
#   base row source without the arguments - and materialising a bound
#   derived base before the fold runs retired it; its cells are live
#   above. The JOIN above an inner `?` is NOT the same thing: it refuses
#   at PLAN time, in plan_join_bound's own copy of the old guard.)
refusesq "a derived side written AFTER an ON-with-?" "SELECT A.ID FROM EMP A JOIN DEPT D ON D.ID = A.DEPT_ID AND D.ID > ? JOIN (SELECT ID FROM EMP WHERE ID > ?) B ON B.ID = A.ID ORDER BY A.ID" '[0,0]'

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
# A SORT ABOVE A DERIVED TABLE sorts the BASE RECORDS and runs the
# inner projection at DELIVERY - so the rows that precede the raiser IN
# SORTED ORDER still ship. Sorting already-projected rows cannot do
# that: the projection has run for every row before the first ships.
# The rewrite is exact only when every outer key is a plain FIELD
# naming a plain inner column; a key that needs the EXPRESSION must be
# computed before the sort on the engine too, and blocks on both sides.
stream "a sorted derived table still delivers before its raiser" \
       "SELECT * FROM (SELECT ID, 10/(ID-3) AS Q FROM EMP) X ORDER BY ID"
stream "... and DESC, where sorted order decides WHICH rows ship" \
       "SELECT * FROM (SELECT ID, 10/(ID-3) AS Q FROM EMP) X ORDER BY ID DESC"
stream "control: a sorted derived table with no raiser" \
       "SELECT * FROM (SELECT ID, SALARY FROM EMP) X ORDER BY ID DESC"
stream "control: an outer WHERE above the sort" \
       "SELECT * FROM (SELECT ID, SALARY FROM EMP) X WHERE ID > 1 ORDER BY SALARY"
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
blocks "a sort key that IS the raiser blocks" \
       "SELECT * FROM (SELECT ID, 10/(ID-3) AS Q FROM EMP) X ORDER BY Q"

rm -f "$A" "$B"



if [ "$ran" -lt 175 ]; then
    echo "DIFF only $ran checks ran (expected at least 175) - did one silently skip?"
    fail=1
fi
exit $fail
