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
# THE FETCH BATCH. A LATERAL wider than one batch used to HANG any client
# that honours the protocol's flow control: no plan arm materialised one,
# so control fell through to the streaming emit, which writes every row it
# has into a single response and never consults the count `op_fetch` asked
# for. Measured: node-firebird returned 2340 rows and hung at 2370, one
# batch boundary later, while the engine answered both in under a second.
# isql is BLIND to this - it buffers whatever arrives and printed all 3000
# rows from both servers - so the batch checks below must stay on the node
# driver. This is why the gate builds a 3000-row lateral on purpose.
#
# COMPOSITION. A LATERAL is a row source like any other, so DISTINCT,
# FIRST/SKIP/ROWS, an outer WHERE or ORDER BY, a derived table wrapping it
# and an aggregate over that derived table all have to work. They did not:
# the derived forms PREPARED - handing the client a valid SQLDA it caches -
# and only then died at fetch, which is worse than a refusal.
#
# THE DESCRIBE. Probed against the engine: the COMMA (cross) form carries
# the inner column's own nullability through unchanged, so a NOT NULL
# column (and a literal) stays NOT NULL; the LEFT form is always nullable,
# because an unmatched outer row is NULL-padded. That difference lives
# entirely in the describe, and fire-crab announced everything nullable.
#
# SCOPE: a single base TABLE (aliased or not), then `, LATERAL (...) x` or
# `LEFT JOIN LATERAL (...) x ON TRUE`. The subquery correlates on the outer
# columns in its WHERE and may aggregate. Refused (later slices): a base
# that is itself a join, INNER/RIGHT/FULL JOIN LATERAL, a LEFT LATERAL with
# an ON other than TRUE, an aggregate applied DIRECTLY to the lateral join
# (`SELECT COUNT(*) FROM T a, LATERAL (...) l` - the same query through an
# explicit derived table IS served, and is checked below), and a `?` inside
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
CREATE TABLE SIX (N INTEGER);
CREATE TABLE BIG (ID INTEGER);
CREATE TABLE NN (K INTEGER, W INTEGER NOT NULL);
CREATE SEQUENCE S1;
COMMIT;
INSERT INTO T VALUES (1,10,5); INSERT INTO T VALUES (2,20,3); INSERT INTO T VALUES (3,30,9);
INSERT INTO U VALUES (1,10,100); INSERT INTO U VALUES (2,10,200); INSERT INTO U VALUES (3,20,300);
INSERT INTO SIX VALUES (1); INSERT INTO SIX VALUES (2); INSERT INTO SIX VALUES (3);
INSERT INTO SIX VALUES (4); INSERT INTO SIX VALUES (5); INSERT INTO SIX VALUES (6);
INSERT INTO NN VALUES (1, 42);
COMMIT;
/* 500 outer rows x 6 lateral rows = 3000, which is several fetch
   batches - the whole point of the batch checks */
INSERT INTO BIG (ID) SELECT NEXT VALUE FOR S1 FROM RDB\$TYPES A, RDB\$TYPES B ROWS 500;
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
    # a 3000-row result is 100KB of JSON; compare it whole, print a head
    if [ "$a" = "$b" ]; then
        if [ "${#a}" -gt 120 ]; then echo "OK   $1: ${#a} bytes, $(printf '%.100s' "$a")..."
        else echo "OK   $1: $a"; fi
    else
        echo "DIFF $1"
        echo "     fcwire: $(printf '%.300s' "$a")"
        echo "     engine: $(printf '%.300s' "$b")"
        fail=1
    fi
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


# the fixture must actually be big, or the batch checks prove nothing
big=$(query "SELECT COUNT(*) AS C FROM BIG" 127.0.0.1 "$REAL" "$B")
case "$big" in *500*) ;; *) echo "FAIL fixture BIG is $big, expected 500"; fail=1;; esac

echo "--- past the fetch batch boundary (node only - isql cannot see this) --"
BIGQ="SELECT A.ID, X.V FROM BIG A, LATERAL (SELECT S.N * A.ID AS V FROM SIX S) X"
both "3000-row lateral"        "$BIGQ ORDER BY A.ID, X.V"
both "just inside one batch"   "$BIGQ WHERE A.ID <= 100 ORDER BY A.ID, X.V"
both "LEFT form, 3000 rows"    "SELECT A.ID, X.V FROM BIG A LEFT JOIN LATERAL (SELECT S.N * A.ID AS V FROM SIX S) X ON TRUE ORDER BY A.ID, X.V"
both "filtered past the boundary" "$BIGQ WHERE X.V > 3 ORDER BY A.ID, X.V"

# THE TEETH: the failure was a HANG, and a hang prints nothing - which a
# lazy comparison of two empty results would call a pass. Assert the row
# count and the multiplicity of one outer row directly, against fcwire.
ran=$((ran + 1))
teeth=$(timeout 60 env FC_Q="$BIGQ" FC_PORT="$PORT" FC_DB="$A" node -e '
  process.on("uncaughtException",()=>{console.log("HANG_OR_ERR");process.exit(0);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(0);}
    db.query(process.env.FC_Q,(e2,r)=>{
      if(e2){console.log("ERR");db.detach();process.exit(0);}
      const rows=r||[]; let one=0;
      for(const x of rows){ if(Object.values(x)[0]===1) one++; }
      console.log("rows="+rows.length+" id1x"+one);
      db.detach();process.exit(0);});});' 2>/dev/null)
if [ "$teeth" = "rows=3000 id1x6" ]; then
    echo "OK   teeth: 3000 rows returned, outer row 1 appears exactly 6 times"
else
    echo "DIFF teeth: expected 'rows=3000 id1x6', got '${teeth:-<nothing - the driver hung>}'"
    fail=1
fi

echo "--- a LATERAL composes: modifiers, a derived table, aggregates --------"
both "DISTINCT over a lateral"  "SELECT DISTINCT X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ORDER BY X.W"
both "FIRST over a lateral"     "SELECT FIRST 2 A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ORDER BY A.ID, X.W"
both "FIRST SKIP over a lateral" "SELECT FIRST 1 SKIP 1 A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ORDER BY A.ID, X.W"
both "ROWS over a lateral"      "SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X ORDER BY A.ID, X.W ROWS 2"
both "FIRST past the boundary"  "SELECT FIRST 2400 A.ID, X.V FROM BIG A, LATERAL (SELECT S.N * A.ID AS V FROM SIX S) X ORDER BY A.ID, X.V"
both "derived over a lateral"   "SELECT Y.W FROM (SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X) Y WHERE Y.W > 150 ORDER BY Y.W"
both "COUNT over the derived"   "SELECT COUNT(*) AS C FROM (SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X) Y"
both "SUM over the derived"     "SELECT SUM(Y.W) AS S FROM (SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X) Y"
both "GROUP BY over the derived" "SELECT Y.ID, COUNT(*) AS C FROM (SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X) Y GROUP BY Y.ID ORDER BY Y.ID"
both "HAVING over the derived"  "SELECT Y.ID, COUNT(*) AS C FROM (SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X) Y GROUP BY Y.ID HAVING COUNT(*) > 1 ORDER BY Y.ID"
both "DISTINCT over the derived" "SELECT DISTINCT Y.W FROM (SELECT A.ID, X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X) Y ORDER BY Y.W"
both "aggregate over the big derived" \
    "SELECT COUNT(*) AS C, SUM(Y.V) AS S FROM (SELECT A.ID, X.V FROM BIG A, LATERAL (SELECT S.N * A.ID AS V FROM SIX S) X) Y"

echo "--- the describe: which lateral column is announced nullable ----------"
# node reads the null BITMAP, so it cannot see a wrong nullable BIT at all
# - only the SQLDA does. isql is the right client here for the same reason
# it was the wrong one above.
dsc() { # <dsn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\nSET HEADING OFF;\n%s;\n' "$2" |
        timeout 30 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE '^ *0[0-9]: sqltype' | sed 's/  */ /g' | paste -sd'|'
}
desc() { # <label> <sql>
    local a b
    ran=$((ran + 1))
    a=$(dsc "127.0.0.1/$PORT:$A" "$2"); b=$(dsc "127.0.0.1/$REAL:$B" "$2")
    if [ "$a" = "$b" ] && [ -n "$a" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}
desc "comma over NOT NULL stays fixed" "SELECT X.W FROM T A, LATERAL (SELECT W FROM NN WHERE K = A.ID) X"
desc "LEFT over NOT NULL is nullable"  "SELECT X.W FROM T A LEFT JOIN LATERAL (SELECT W FROM NN WHERE K = A.ID) X ON TRUE"
desc "comma over a nullable column"    "SELECT X.W FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X"
desc "comma over a literal"            "SELECT X.Z FROM T A, LATERAL (SELECT 7 AS Z FROM RDB\$DATABASE) X"
desc "an expression over a fixed col"  "SELECT X.W + 1 FROM T A, LATERAL (SELECT W FROM NN WHERE K = A.ID) X"
desc "COALESCE over the LEFT form"     "SELECT COALESCE(X.W, 0) FROM T A LEFT JOIN LATERAL (SELECT W FROM NN WHERE K = A.ID) X ON TRUE"
desc "base and lateral columns both"   "SELECT A.ID, X.W FROM T A, LATERAL (SELECT W FROM NN WHERE K = A.ID) X"

echo "--- recorded boundary: an aggregate applied DIRECTLY to the join ------"
# The engine answers this; fire-crab refuses at PREPARE. A refusal is a
# boundary we accept - a wrong answer, or a prepare that succeeds and then
# fails at fetch, is not. Spelled through a derived table it IS served
# (checked above), so nothing here is unreachable.
ran=$((ran + 1))
direct=$(query "SELECT COUNT(*) AS C FROM T A, LATERAL (SELECT U.W FROM U WHERE U.UG = A.G) X" 127.0.0.1 "$PORT" "$A")
case "$direct" in
    ERR*) echo "OK   direct aggregate over the lateral join refuses cleanly: $direct" ;;
    *)    echo "DIFF direct aggregate: expected a refusal, got '$direct' - if this now"
          echo "     answers, check it against the engine and move it into the"
          echo "     composition block above rather than deleting this check"
          fail=1 ;;
esac

echo "ran $ran checks"
[ "$ran" -ge 35 ] || { echo "FAIL only $ran checks ran"; fail=1; }
exit $fail
