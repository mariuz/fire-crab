#!/bin/bash
# DECODE and EXISTS as SELECT-LIST VALUES - against the REAL engine as a
# twin: the same driver, the same statement, two servers, two identical
# databases.
#
# Both are constructs the engine has and this select list refused, and
# both are answered by machinery that already existed:
#
#   * DECODE(<subject>, <search>, <result>, ..., [<default>]) IS a simple
#     CASE - the engine compiles it to the same node - so it desugars to
#     the searched form the parser already builds, one `= comparison` per
#     pair. An ODD number of arguments after the subject ends with a
#     DEFAULT; an even number has none and no match answers NULL.
#   * EXISTS(SELECT ...) folds to TRUE or FALSE at prepare, through the
#     same subquery lifting the select list already uses - it asks only
#     whether a row survives, which is what `existence_only` means.
#
# THE LAW WORTH PROBING, because it is the one a converter inherits
# wrongly: Firebird's DECODE does NOT match a NULL subject to a NULL
# search value. Oracle's does. Here the comparison is `=`, and `NULL =
# NULL` is UNKNOWN, so a NULL subject matches nothing and falls to the
# default - which is exactly what the simple-CASE desugar gives for free,
# and would have been wrong if the desugar had been written to Oracle's
# semantics.
#
# THE OTHER LAW is about NAMES, not values: DECODE compiles to a CASE and
# is still described as DECODE, while a simple CASE is described as CASE.
# The gate puts the two side by side in ONE select list, which is the
# only place the difference shows. A desugar that preserved every value
# would have changed the contract.
#
# NOT CHECKED HERE, and recorded rather than hidden: the engine gives a
# conditional's TEXT result the width of its WIDEST branch and pads
# shorter values to it - `CASE WHEN ... THEN 'other' ELSE 'isnull' END`
# describes as CHAR(6) and answers `'other '`. fire-crab announces a
# VARCHAR and does not pad. That divergence is PRE-EXISTING and belongs
# to plain CASE as much as to DECODE (both differ identically), so the
# text checks below use branches of EQUAL width and the padding law is
# named as the next slice instead of being quietly encoded here.
#
#   qa/serve-real-decode.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4548}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-dec-crab.fdb"
B="$D/fc-dec-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# EMP 5 has a NULL department - the row the NULL-matching law turns on.
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

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-decode.log 2>&1 &
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

# --- 0. the controls, which DECODE compiles into ----------------------
both "a simple CASE" \
     "SELECT ID, CASE DEPT_ID WHEN 1 THEN 'aa' ELSE 'zz' END FROM EMP ORDER BY ID"
both "a searched CASE" \
     "SELECT ID, CASE WHEN DEPT_ID = 1 THEN 'aa' ELSE 'zz' END FROM EMP ORDER BY ID"

# --- 1. DECODE ---------------------------------------------------------
both "one pair and a default" \
     "SELECT ID, DECODE(DEPT_ID, 1, 'aa', 'zz') FROM EMP ORDER BY ID"
both "two pairs and a default" \
     "SELECT ID, DECODE(DEPT_ID, 1, 'aa', 2, 'bb', 'zz') FROM EMP ORDER BY ID"
both "NO default: an unmatched row is NULL" \
     "SELECT ID, DECODE(DEPT_ID, 1, 'aa', 2, 'bb') FROM EMP ORDER BY ID"
both "numeric results" \
     "SELECT ID, DECODE(DEPT_ID, 1, 10, 2, 20, 99) FROM EMP ORDER BY ID"
both "numeric results with no default" \
     "SELECT ID, DECODE(DEPT_ID, 1, 10, 2, 20) FROM EMP ORDER BY ID"
both "an EXPRESSION as the subject" \
     "SELECT ID, DECODE(DEPT_ID + 1, 2, 10, 3, 20, 99) FROM EMP ORDER BY ID"
both "expressions as the results" \
     "SELECT ID, DECODE(DEPT_ID, 1, SALARY * 2, SALARY) FROM EMP ORDER BY ID"
both "a text column as the subject" \
     "SELECT ID, DECODE(NAME, 'a', 10, 'b', 20, 99) FROM EMP ORDER BY ID"

# --- 2. the NULL law, which Oracle would get wrong --------------------
# EMP 5's department is NULL: the comparison is `=`, and NULL = NULL is
# UNKNOWN, so it matches NOTHING and takes the default
both "a NULL subject does NOT match a NULL search" \
     "SELECT ID, DECODE(DEPT_ID, NULL, 'yy', 'nn') FROM EMP ORDER BY ID"
both "... and with no default it is NULL" \
     "SELECT ID, DECODE(DEPT_ID, NULL, 'yy') FROM EMP ORDER BY ID"
both "a NULL subject against ordinary searches" \
     "SELECT ID, DECODE(DEPT_ID, 1, 'aa', 2, 'bb', 'zz') FROM EMP WHERE ID = 5"

# --- 3. the NAMING law, which only shows side by side -----------------
both "DECODE beside a simple CASE in one list" \
     "SELECT CASE DEPT_ID WHEN 1 THEN 'aa' END, DECODE(DEPT_ID, 1, 'aa') FROM EMP WHERE ID = 1"
both "an explicit alias wins" \
     "SELECT ID, DECODE(DEPT_ID, 1, 'aa', 'zz') AS D FROM EMP WHERE ID = 1"

# --- 4. what DECODE flows into ----------------------------------------
both "inside an expression" \
     "SELECT ID, DECODE(DEPT_ID, 1, 10, 20) + 1 FROM EMP ORDER BY ID"
both "inside a CAST" \
     "SELECT ID, CAST(DECODE(DEPT_ID, 1, 10, 20) AS VARCHAR(4)) FROM EMP ORDER BY ID"
both "as an ORDER BY key" \
     "SELECT ID FROM EMP ORDER BY DECODE(DEPT_ID, 1, 9, 0), ID"
# DECODE inside a WHERE refuses: the predicate tokenizer spans a CASE by
# its balancing END (`matching_case_end`) and has no rule for a DECODE
# call, so the desugar the select list gets never reaches it. Named here
# rather than left as an unexplained gap.
refuses "DECODE inside a WHERE" \
        "SELECT COUNT(*) FROM EMP WHERE DECODE(DEPT_ID, 1, 10, 20) = 10"
both "under an aggregate" "SELECT SUM(DECODE(DEPT_ID, 1, 10, 0)) FROM EMP"

# --- 5. EXISTS as a select-list VALUE ---------------------------------
both "EXISTS that is TRUE" "SELECT ID, EXISTS(SELECT 1 FROM DEPT) FROM EMP WHERE ID = 1"
both "EXISTS that is FALSE" \
     "SELECT ID, EXISTS(SELECT 1 FROM DEPT WHERE ID = 99) FROM EMP WHERE ID = 1"
both "EXISTS alone in the list" "SELECT EXISTS(SELECT 1 FROM DEPT) FROM EMP WHERE ID = 1"
both "EXISTS with an alias" \
     "SELECT ID, EXISTS(SELECT 1 FROM DEPT) AS X FROM EMP WHERE ID = 1"
both "EXISTS over a filtered subquery" \
     "SELECT ID, EXISTS(SELECT 1 FROM DEPT WHERE ID > 2) FROM EMP WHERE ID = 1"
both "TWO of them" \
     "SELECT EXISTS(SELECT 1 FROM DEPT) AS A, EXISTS(SELECT 1 FROM DEPT WHERE ID = 99) AS B
      FROM EMP WHERE ID = 1"
# the WHERE's own EXISTS is unchanged
both "EXISTS still filters in a WHERE" \
     "SELECT COUNT(*) FROM EMP WHERE EXISTS(SELECT 1 FROM DEPT WHERE ID = 1)"

# --- 6. the refusals --------------------------------------------------
refuses "DECODE with no pair at all" "SELECT DECODE(DEPT_ID) FROM EMP"
refuses "DECODE with a subject only" "SELECT DECODE(DEPT_ID, 1) FROM EMP"

rm -f "$A" "$B"
if [ "$ran" -lt 28 ]; then
    echo "DIFF only $ran checks ran (expected at least 28) - did one silently skip?"
    fail=1
fi
exit $fail
