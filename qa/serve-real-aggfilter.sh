#!/bin/bash
# The aggregate FILTER clause - `<agg>(arg) FILTER (WHERE <cond>)` in a
# select list. Only the rows the condition accepts fold into the
# aggregate; COUNT(*) FILTER counts the matching rows, and an all-rejected
# group is COUNT 0 / SUM NULL - SQL's empty aggregate.
#
# fire-crab answers it by an exact rewrite - `<agg>(arg) FILTER (WHERE c)`
# is `<agg>(CASE WHEN c THEN arg END)` (COUNT(*) is COUNT over `CASE WHEN c
# THEN 1 END`): a non-matching row becomes NULL and drops out of the fold,
# identical in value AND describe (checked against the engine's SQLDA), so
# no new fold machinery is needed. node-firebird drives fire-crab and the
# live engine with the same query; results must be identical.
#
# SCOPE: a FILTER on a bare aggregate select item, over COUNT/SUM/MIN/MAX/
# AVG. A FILTER on a WINDOW aggregate (... OVER ...), a FILTER inside a
# larger expression (`SUM(x) FILTER (...) + 1`), a COUNT(DISTINCT ...)
# FILTER, and a FILTER inside a HAVING clause are each refused at prepare
# (their own later slices).
#
#   qa/serve-real-aggfilter.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4769}"
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
CREATE TABLE T (ID INTEGER, G INTEGER, V INTEGER, N92 NUMERIC(9,2), NM VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1,10,5,1.50,'a'); INSERT INTO T VALUES (2,10,3,2.50,'b'); INSERT INTO T VALUES (3,10,9,3.00,NULL);
INSERT INTO T VALUES (4,20,1,4.00,'d'); INSERT INTO T VALUES (5,20,7,5.00,'e'); INSERT INTO T VALUES (6,20,8,6.00,'f');
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-aggfilter-a.fdb"; B="$D/fc-aggfilter-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-aggfilter-$PORT.log 2>&1 &
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

both "COUNT(*) FILTER"       "SELECT G, COUNT(*) FILTER (WHERE V>5) C FROM T GROUP BY G ORDER BY G"
both "SUM FILTER"            "SELECT G, SUM(V) FILTER (WHERE V>5) S FROM T GROUP BY G ORDER BY G"
both "COUNT(col) FILTER"     "SELECT G, COUNT(NM) FILTER (WHERE V>0) C FROM T GROUP BY G ORDER BY G"
both "AVG FILTER"            "SELECT G, AVG(V) FILTER (WHERE V>=5) A FROM T GROUP BY G ORDER BY G"
both "MIN text FILTER"       "SELECT G, MIN(NM) FILTER (WHERE V>0) M FROM T GROUP BY G ORDER BY G"
both "MAX FILTER"            "SELECT G, MAX(V) FILTER (WHERE V<8) M FROM T GROUP BY G ORDER BY G"
both "SUM numeric FILTER"    "SELECT G, SUM(N92) FILTER (WHERE V>3) S FROM T GROUP BY G ORDER BY G"
both "all-rejected group"    "SELECT G, COUNT(*) FILTER (WHERE V>100) C, SUM(V) FILTER (WHERE V>100) S FROM T GROUP BY G ORDER BY G"
both "global no group"       "SELECT COUNT(*) FILTER (WHERE V>5) C, SUM(V) FILTER (WHERE V>5) S FROM T"
both "filtered + plain"      "SELECT G, COUNT(*) C, COUNT(*) FILTER (WHERE V>5) CF FROM T GROUP BY G ORDER BY G"
both "filter cond AND/NULL"  "SELECT G, SUM(V) FILTER (WHERE V>2 AND NM IS NOT NULL) S FROM T GROUP BY G ORDER BY G"
both "filter on other col"   "SELECT G, COUNT(*) FILTER (WHERE G=10) C FROM T GROUP BY G ORDER BY G"
both "two filters one query" "SELECT G, SUM(V) FILTER (WHERE V>5) HI, SUM(V) FILTER (WHERE V<=5) LO FROM T GROUP BY G ORDER BY G"
both "COUNT(*) FILTER OR"    "SELECT COUNT(*) FILTER (WHERE V<2 OR V>7) C FROM T"

echo "ran $ran checks"
exit $fail
