#!/bin/bash
# CAST(? AS <type>) in the SELECT LIST of a GROUPED query - a `?`
# projection parameter beside aggregates and group keys. The projection
# `?` cast landed for a plain SELECT, a join and a derived table; this
# extends it to a grouped query, riding on the projected-constant slot
# (qa/serve-real-groupconst.sh): a typed CAST(? AS ..) references no
# column, so the group builder gives it a GItem::Const placeholder slot
# and carries the cast expression on its output column, bound at execute.
#
# Driven by node-firebird (like the derived gate): each case runs the
# same statement and argument list against fire-crab and the live engine
# and compares the rows.
#
#   * the projection `?` converts the bound value by the cast grammar,
#     the same value in every group row;
#   * covered across all three grouped shapes that share
#     build_group_items - plain GROUP BY, the implicit whole-table
#     aggregate, a grouped JOIN and a grouped derived table;
#   * a projection `?` numbers before the WHERE, one textual order.
#
# SCOPE: the group projection param itself. A `?` in a WHERE/HAVING of a
# grouped query, and an expression over a grouping column (SELECT V*2 ...
# GROUP BY V), are separate slices.
#
#   qa/serve-real-castparamgroup.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4753}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node-firebird")' >/dev/null 2>&1; then
    echo "SKIP: node-firebird not available"; exit 0
fi
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
CREATE TABLE U (ID INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10); INSERT INTO T VALUES (2,10); INSERT INTO T VALUES (3,20);
INSERT INTO U VALUES (1,100); INSERT INTO U VALUES (3,300);
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-castparamgroup-a.fdb"; B="$D/fc-castparamgroup-b.fdb"
make_db "$A"; make_db "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castparamgroup-$PORT.log 2>&1 &
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
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,40));db.detach();process.exit(0);}
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

both "plain group, rounds"        "SELECT CAST(? AS INTEGER) AS C, COUNT(*) AS N FROM T GROUP BY V" "[2.5]"
both "group, key + order"         "SELECT V, CAST(? AS INTEGER) AS C, COUNT(*) AS N FROM T GROUP BY V ORDER BY V" "[42]"
both "implicit whole-table agg"   "SELECT CAST(? AS INTEGER) AS C, SUM(V) AS S FROM T" "[7]"
both "grouped join, smallint"     "SELECT CAST(? AS SMALLINT) AS C, COUNT(*) AS N FROM T JOIN U ON T.ID = U.ID GROUP BY T.V" "[9]"
both "grouped derived table"      "SELECT CAST(? AS INTEGER) AS C, COUNT(*) AS N FROM (SELECT V FROM T) X GROUP BY X.V" "[100]"
both "group, bigint target"       "SELECT CAST(? AS BIGINT) AS C, COUNT(*) AS N FROM T GROUP BY V" "[9999999999]"
both "group, width overflow"      "SELECT CAST(? AS SMALLINT) AS C, COUNT(*) AS N FROM T GROUP BY V" "[99999]"

echo "ran $ran checks"
exit $fail
