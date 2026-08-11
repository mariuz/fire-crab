#!/bin/bash
# A `?` PARAMETER in a HAVING clause - HAVING COUNT(*) > ?. A grouped
# WHERE `?` already worked; HAVING refused every `?` (the resolver's
# throwaway counter). The HAVING resolver now claims the slot with the
# compared value's describe - the aggregate output (INT64, probed 580
# for COUNT and SUM(int)) or the grouped key's own type - and the HAVING
# predicate is bound at execute like the WHERE filter.
#
# The `?` numbers in ONE textual order after the projection and WHERE
# params (probed: WHERE ? then HAVING ? is input slots 0, 1). Driven by
# node-firebird against fire-crab and the live engine, rows compared.
#
# SCOPE: an integer aggregate (COUNT / SUM over an integer) or a grouped
# key on the tested side. A HAVING `?` against a NUMERIC or TEXT
# aggregate is a separate slice (its slot describe is unprobed), and so
# is a `?` on the AGGREGATE side of the comparison.
#
#   qa/serve-real-havingparam.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4765}"
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
CREATE TABLE T (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10); INSERT INTO T VALUES (2,10); INSERT INTO T VALUES (3,20);
INSERT INTO T VALUES (4,30); INSERT INTO T VALUES (5,30); INSERT INTO T VALUES (6,30);
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-havingparam-a.fdb"; B="$D/fc-havingparam-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-havingparam-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

query() { # <sql> <json args> <host> <port> <db>
    timeout 25 env FC_Q="$1" FC_A="$2" FC_HOST="$3" FC_PORT="$4" FC_DB="$5" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird");
      const args=JSON.parse(process.env.FC_A);
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,args,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,44));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
both() { # <label> <sql> <json args>
    local a b
    a=$(query "$2" "$3" 127.0.0.1 "$PORT" "$A")
    b=$(query "$2" "$3" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}

both "HAVING COUNT(*) > ?"        "SELECT V, COUNT(*) AS N FROM T GROUP BY V HAVING COUNT(*) > ? ORDER BY V"  "[1]"
both "HAVING COUNT(*) > ? (none)" "SELECT V, COUNT(*) AS N FROM T GROUP BY V HAVING COUNT(*) > ? ORDER BY V"  "[10]"
both "HAVING SUM(ID) > ?"         "SELECT V, SUM(ID) AS S FROM T GROUP BY V HAVING SUM(ID) > ? ORDER BY V"    "[5]"
both "HAVING COUNT(*) >= ?"       "SELECT V, COUNT(*) AS N FROM T GROUP BY V HAVING COUNT(*) >= ? ORDER BY V" "[2]"
both "HAVING on group key"        "SELECT V, COUNT(*) AS N FROM T GROUP BY V HAVING V > ? ORDER BY V"         "[10]"
# a WHERE ? and a HAVING ? together, numbered in textual order
both "WHERE ? + HAVING ?"         "SELECT V, COUNT(*) AS N FROM T WHERE ID > ? GROUP BY V HAVING COUNT(*) >= ? ORDER BY V" "[1,2]"
# implicit whole-table aggregate with a HAVING ?
both "implicit agg HAVING ?"      "SELECT COUNT(*) AS N FROM T HAVING COUNT(*) > ?" "[3]"

echo "ran $ran checks"
exit $fail
