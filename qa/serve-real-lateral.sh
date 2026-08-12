#!/bin/bash
# LATERAL derived tables - a correlated derived table in the FROM:
#
#   FROM <base> a, LATERAL (<subquery referencing a.col>) x
#   FROM <base> a LEFT JOIN LATERAL (<subquery>) x ON TRUE
#
# The subquery references the OUTER (base) row's columns, so it is
# re-evaluated per outer row. A comma / cross LATERAL drops an outer row
# whose subquery is empty; LEFT JOIN LATERAL keeps it, NULL-padded; an
# aggregated subquery always yields one row (so every outer row survives).
#
# fire-crab's join planner cannot bind an outer row into a side's inner
# plan, so it threads the correlation by SUBSTITUTION: at fetch, each outer
# row's columns are rendered as literals into the subquery, which is then
# an ordinary uncorrelated query, planned and run. The describe is resolved
# once by the ordinary join planner over a NULL-typed stand-in. node-fire
# bird drives fire-crab and the live engine with the same query; the row
# sets must be identical.
#
# SCOPE: a single base TABLE (aliased or not), then `, LATERAL (...) x` or
# `LEFT JOIN LATERAL (...) x ON TRUE`. The subquery correlates on the outer
# columns in its WHERE and may aggregate. Refused (later slices): a base
# that is itself a join, INNER/RIGHT/FULL JOIN LATERAL, a LEFT LATERAL with
# an ON other than TRUE, a GROUP BY over the lateral join, and a `?` inside
# the subquery.
#
#   qa/serve-real-lateral.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4770}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node-firebird")' >/dev/null 2>&1; then
    echo "SKIP: node-firebird not available"; exit 0
fi
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, G INTEGER, V INTEGER);
CREATE TABLE U (UID INTEGER, UG INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10,5); INSERT INTO T VALUES (2,20,3); INSERT INTO T VALUES (3,30,9);
INSERT INTO U VALUES (1,10,100); INSERT INTO U VALUES (2,10,200); INSERT INTO U VALUES (3,20,300);
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-lateral-a.fdb"; B="$D/fc-lateral-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-lateral-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

query() { # <sql> <host> <port> <db>
    timeout 25 env FC_Q="$1" FC_HOST="$2" FC_PORT="$3" FC_DB="$4" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird");
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,44));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
both() { # <label> <sql>
    local a b
    a=$(query "$2" 127.0.0.1 "$PORT" "$A")
    b=$(query "$2" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}

both "comma correlated table"  "SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ORDER BY A.ID, X.W"
both "comma correlated agg"    "SELECT A.ID, X.S FROM T A, LATERAL (SELECT SUM(U.W) AS S FROM U WHERE U.UG = A.G) X ORDER BY A.ID"
both "comma count col"         "SELECT A.ID, X.C FROM T A, LATERAL (SELECT COUNT(*) AS C FROM U WHERE U.UG = A.G) X ORDER BY A.ID"
both "comma two lateral cols"  "SELECT A.ID, X.MN, X.MX FROM T A, LATERAL (SELECT MIN(W) MN, MAX(W) MX FROM U WHERE U.UG = A.G) X ORDER BY A.ID"
both "comma const expr"        "SELECT A.ID, X.V2 FROM T A, LATERAL (SELECT A.V * 2 AS V2 FROM RDB\$DATABASE) X ORDER BY A.ID"
both "outer WHERE over lateral" "SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X WHERE X.W > 150 ORDER BY A.ID, X.W"
both "no-alias base"           "SELECT T.ID, X.W FROM T, LATERAL (SELECT U.W FROM U WHERE U.UG = T.G) X ORDER BY T.ID, X.W"
both "base column projected"   "SELECT A.G, A.V, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ORDER BY A.ID, X.W"
both "LEFT JOIN LATERAL"       "SELECT A.ID, X.W FROM T A LEFT JOIN LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ON TRUE ORDER BY A.ID, X.W"
both "LEFT LATERAL aggregate"  "SELECT A.ID, X.S FROM T A LEFT JOIN LATERAL (SELECT SUM(U.W) S FROM U WHERE U.UG = A.G) X ON TRUE ORDER BY A.ID"
both "lateral two-cond corr"   "SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G AND U.W > A.V) X ORDER BY A.ID, X.W"

echo "ran $ran checks"
exit $fail
