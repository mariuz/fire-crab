#!/bin/bash
# WINDOW functions - an aggregate with an OVER clause, answered on every
# input row: `<agg>(arg) OVER ( [PARTITION BY ...] )`. The rows are
# bucketed by the PARTITION BY keys (NULLs bucket together, as GROUP BY
# does), each bucket folded by the same machinery a grouped aggregate
# uses, and every row in a bucket answered that bucket's value - one row
# per INPUT row, not per bucket. `OVER ()` is one bucket of the whole
# result. The value's describe is the aggregate's own (COUNT -> BIGINT,
# MIN/MAX -> the source type, SUM/AVG widened at the source scale), named
# by the function unless aliased - the SAME contract a bare aggregate has.
#
# node-firebird drives fire-crab; isql-created twin answers the same query
# from the live engine; the row sets must be identical. Covered: COUNT/
# SUM/MIN/MAX/AVG, integer / NUMERIC / text sources, one- and two-column
# partitions, `OVER ()`, several windows in one select, a window beside
# plain columns and an expression, a WHERE before the window, a NULL
# partition key, ORDER BY on the window column, and COUNT(DISTINCT) OVER.
#
# SCOPE - THE WHOLE-PARTITION FRAME. An ORDER BY or an explicit frame
# (ROWS/RANGE) inside the OVER answers a RUNNING value this build does not
# compute; a ranking (ROW_NUMBER, RANK, DENSE_RANK) or navigation (LAG,
# LEAD) function is not an aggregate; a window over a JOIN or a derived /
# CTE / union-branch row source, a window mixed with GROUP BY, and a `?`
# inside a window - each refuses at prepare and is its own later slice.
#
#   qa/serve-real-window.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4767}"
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
CREATE TABLE T (ID INTEGER, G INTEGER, H INTEGER, V INTEGER, N92 NUMERIC(9,2), NM VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1,10,1,5,1.50,'aa'); INSERT INTO T VALUES (2,10,1,3,2.50,'bb');
INSERT INTO T VALUES (3,20,1,9,5.00,'cc'); INSERT INTO T VALUES (4,20,2,9,1.00,'dd');
INSERT INTO T VALUES (5,30,2,1,2.00,'ee'); INSERT INTO T VALUES (6,30,2,7,3.00,NULL);
INSERT INTO T VALUES (7,NULL,NULL,4,NULL,'gg');
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-window-a.fdb"; B="$D/fc-window-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-window-$PORT.log 2>&1 &
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

both "COUNT(*) OVER ()"        "SELECT ID, COUNT(*) OVER () C FROM T ORDER BY ID"
both "SUM OVER (PARTITION)"    "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM T ORDER BY ID"
both "MAX OVER (PARTITION)"    "SELECT ID, MAX(V) OVER (PARTITION BY G) M FROM T ORDER BY ID"
both "AVG OVER (PARTITION)"    "SELECT ID, AVG(V) OVER (PARTITION BY G) A FROM T ORDER BY ID"
both "MIN text OVER"           "SELECT ID, MIN(NM) OVER (PARTITION BY G) M FROM T ORDER BY ID"
both "SUM numeric OVER"        "SELECT ID, SUM(N92) OVER (PARTITION BY G) S FROM T ORDER BY ID"
both "COUNT(col) OVER"         "SELECT ID, COUNT(NM) OVER (PARTITION BY G) C FROM T ORDER BY ID"
both "two-column partition"    "SELECT ID, SUM(V) OVER (PARTITION BY G, H) S FROM T ORDER BY ID"
both "two windows"             "SELECT ID, SUM(V) OVER (PARTITION BY G) S, COUNT(*) OVER () C FROM T ORDER BY ID"
both "window + plain + expr"   "SELECT ID, V, V*2 D, AVG(V) OVER (PARTITION BY G) A FROM T ORDER BY ID"
both "WHERE then window"       "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM T WHERE ID>2 ORDER BY ID"
both "NULL partition key"      "SELECT ID, COUNT(*) OVER (PARTITION BY G) C FROM T ORDER BY ID"
both "ORDER BY window column"  "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM T ORDER BY S, ID"
both "no alias -> named SUM"   "SELECT SUM(V) OVER (PARTITION BY G) FROM T ORDER BY 1"
both "COUNT(DISTINCT) OVER"    "SELECT ID, COUNT(DISTINCT V) OVER (PARTITION BY G) C FROM T ORDER BY ID"
both "AVG numeric OVER ()"     "SELECT ID, AVG(N92) OVER () A FROM T ORDER BY ID"

echo "ran $ran checks"
exit $fail
