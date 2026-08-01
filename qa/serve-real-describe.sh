#!/bin/bash
# The DESCRIBE's two names, against the REAL engine as a twin: item 16
# (isc_info_sql_field, the engine's symbolic/source name) and item 19
# (isc_info_sql_alias, the client's column key), compared for every
# expression class this server can project.
#
# fire-crab had answered the ALIAS in both fields for every aliased
# column since the describe writer was built - invisible to a client
# that reads only `alias` (node-firebird keys rows by it), visible in
# isql headers and to anything reading `field`. The engine's rule
# (DsqlAliasNode::setParameterName): every expression node sets BOTH
# names to its symbolic name; the user's AS overwrites ONLY the alias.
#
# The engine answers probed and pinned here include the surprises:
#   * unary minus has an EMPTY field name (and empty alias, unaliased);
#   * NULLIF describes as CASE - it compiles into one;
#   * a scalar subquery delegates naming to its INNER item, whose alias
#     becomes the outer alias;
#   * UNION columns have an EMPTY field name but keep the first
#     branch's name as the alias;
#   * a derived table lets the BASE name shine through (V.C over
#     `X AS C` is field X) while a VIEW hides it (VC/VC);
#   * NEXT VALUE FOR ... FROM RDB$DATABASE is NEXT_VALUE, not GEN_ID.
#
# NOT compared here: item 17 (relation) and 18 (owner) - fire-crab
# sends "" where the engine sends the table/view/procedure name; that
# is its own slice, noted in the roadmap.
#
#   qa/serve-real-describe.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4478}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-describe-crab.fdb"
B="$D/fc-describe-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER, S VARCHAR(10), D DOUBLE PRECISION);
CREATE GENERATOR G1;
COMMIT;
CREATE VIEW V1 (VC) AS SELECT X FROM T;
CREATE VIEW V2 (E) AS SELECT X + 1 FROM T;
ALTER TABLE T ADD CC COMPUTED BY (X + 1);
SET TERM ^ ;
CREATE PROCEDURE PR RETURNS (R INTEGER) AS BEGIN R = 7; SUSPEND; END^
SET TERM ; ^
COMMIT;
INSERT INTO T (X, S, D) VALUES (1, 'a', 1.5);
INSERT INTO T (X, S, D) VALUES (2, 'b', 2.5);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-describe.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# PREPARE ONLY, never execute: the describe is the whole question, and
# executing would advance G1 differently on the two servers.
describe() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.newStatement(process.env.FC_Q,(e2,st)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              console.log(JSON.stringify((st.output||[]).map(v=>[v.field??"",v.alias??""])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    a=$(describe "$2" "$PORT" "$A")
    b=$(describe "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# --- 1. plain columns and aliases --------------------------------------
both "a plain column" "SELECT X FROM T"
both "an aliased column" "SELECT X AS Z FROM T"
both "a qualified column" "SELECT T.X FROM T"
both "a table-alias-qualified column" "SELECT A.X FROM T A"
both "a quoted alias keeps its case" "SELECT X + 1 AS \"lower\" FROM T"
both "three items, order kept" "SELECT X, X AS Z, UPPER(S) FROM T"

# --- 2. expressions name themselves ------------------------------------
both "ADD" "SELECT X + 1 FROM T"
both "ADD with an alias" "SELECT X + 1 AS Y FROM T"
both "SUBTRACT" "SELECT X - 1 FROM T"
both "MULTIPLY" "SELECT X * 2 FROM T"
both "DIVIDE" "SELECT X / 2 FROM T"
both "unary minus is EMPTY" "SELECT -X FROM T"
both "unary minus keeps only the alias" "SELECT -X AS NEG FROM T"
both "a negated literal is CONSTANT" "SELECT -3 FROM T"
both "CONCATENATION" "SELECT S || 'x' FROM T"
both "UPPER" "SELECT UPPER(S) FROM T"
both "UPPER aliased" "SELECT UPPER(S) AS U FROM T"
both "CAST" "SELECT CAST(X AS BIGINT) FROM T"
both "COALESCE" "SELECT COALESCE(X, 0) FROM T"
both "NULLIF describes as CASE" "SELECT NULLIF(X, 0) FROM T"
both "IIF describes as CASE" "SELECT IIF(X > 0, 1, 0) FROM T"
both "DECODE keeps its own name" "SELECT DECODE(X, 1, 'a', 'b') FROM T"
both "DECODE aliased" "SELECT DECODE(X, 1, 'a', 'b') AS DC FROM T"
both "CASE" "SELECT CASE WHEN X > 0 THEN 1 ELSE 0 END FROM T"
both "a literal is CONSTANT" "SELECT 42 FROM T"
both "an aliased literal" "SELECT 42 AS ANSWER FROM T"
both "NULL aliased" "SELECT NULL AS NOTHING FROM T"
both "a boolean expression is BOOL" "SELECT X > 0 FROM T"

# --- 3. aggregates ------------------------------------------------------
both "COUNT" "SELECT COUNT(*) FROM T"
both "SUM" "SELECT SUM(X) FROM T"
both "AVG" "SELECT AVG(X) FROM T"
both "MIN and MAX" "SELECT MIN(X), MAX(X) FROM T"
both "COUNT keeps its field under an alias" "SELECT COUNT(*) AS N FROM T"
both "SUM keeps its field under an alias" "SELECT SUM(X) AS TOT FROM T"

# --- 4. subqueries delegate to their inner item -------------------------
both "a scalar subquery (aggregate)" "SELECT (SELECT MAX(X) FROM T) FROM RDB\$DATABASE"
both "... with an INNER alias" "SELECT (SELECT MAX(X) AS M FROM T) FROM RDB\$DATABASE"
both "... and an OUTER alias over it" "SELECT (SELECT MAX(X) AS M FROM T) AS SUB FROM RDB\$DATABASE"

# --- 5. generators ------------------------------------------------------
both "GEN_ID" "SELECT GEN_ID(G1, 0) FROM T"
both "GEN_ID aliased" "SELECT GEN_ID(G1, 0) AS G FROM T"
both "NEXT VALUE FOR" "SELECT NEXT VALUE FOR G1 FROM T"
both "NEXT VALUE FOR aliased" "SELECT NEXT VALUE FOR G1 AS NV FROM T"
both "NEXT VALUE over RDB\$DATABASE is NEXT_VALUE" "SELECT NEXT VALUE FOR G1 FROM RDB\$DATABASE"
both "GEN_ID over RDB\$DATABASE" "SELECT GEN_ID(G1, 1) FROM RDB\$DATABASE"

# --- 6. computed columns, views, derived tables, CTEs -------------------
both "a computed column is its own name" "SELECT CC FROM T"
both "a computed column aliased" "SELECT CC AS K FROM T"
both "a view column hides the base" "SELECT VC FROM V1"
both "a view column aliased" "SELECT VC AS W FROM V1"
both "a view over an expression" "SELECT E FROM V2"
both "a derived table lets the base shine through" "SELECT V.C FROM (SELECT X AS C FROM T) V"
both "... an expression inside stays symbolic" "SELECT V.C FROM (SELECT X + 1 AS C FROM T) V"
both "... a constant inside stays CONSTANT" "SELECT V.C FROM (SELECT 42 AS C FROM T) V"
both "a CTE behaves like the derived table" "WITH C AS (SELECT X AS C1 FROM T) SELECT C1 FROM C"

# --- 7. grouping --------------------------------------------------------
both "a group key and its COUNT" "SELECT X, COUNT(*) FROM T GROUP BY X"
both "aliased key, aliased fold" "SELECT X AS K, COUNT(*) AS N FROM T GROUP BY X"
both "a grouped key over a derived table" "SELECT C FROM (SELECT X AS C FROM T) V GROUP BY C"
both "an aggregate over a derived table" "SELECT SUM(C) FROM (SELECT X AS C FROM T) V GROUP BY C"

# --- 8. joins -----------------------------------------------------------
both "a join select list with aliases" "SELECT A.X AS AX, B.S FROM T A JOIN T B ON A.X = B.X"
both "COUNT over a join" "SELECT COUNT(*) AS N FROM T A JOIN T B ON A.X = B.X"

# --- 9. procedures ------------------------------------------------------
both "a selectable procedure's output" "SELECT R FROM PR"
both "... aliased (the alias was dropped once)" "SELECT R AS RR FROM PR"

# --- 10. unions ---------------------------------------------------------
both "a union column's field is EMPTY" "SELECT X FROM T UNION ALL SELECT X + 1 FROM T"
both "... and an aliased first branch names the alias" "SELECT X AS U1 FROM T UNION ALL SELECT X + 1 AS U2 FROM T"

# --- 11. shared refusals ------------------------------------------------
a=$(describe "SELECT ? FROM T" "$PORT" "$A")
b=$(describe "SELECT ? FROM T" "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo "OK   a bare ? in the select list refuses on both" ;;
    *) echo "DIFF bare ?: fcwire [$a] engine [$b]"; fail=1 ;;
esac

rm -f "$A" "$B"
exit $fail
