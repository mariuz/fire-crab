#!/bin/bash
# RE-EXECUTING A PREPARED STATEMENT.
#
# A FETCH MUTATES THE LIVE PLAN: it materialises the plan into
# `Plan::Rows`, drains those rows as it delivers them, and (since the
# cursor-exhaustion fix) marks the plan spent when the cursor finishes.
# So by the time a statement is executed a SECOND time, the plan it
# would run is the wreckage of the first run - and the second execute
# answered ZERO ROWS, with no error.
#
# `SELECT COUNT(*) FROM T` did this long before the exhaustion fix,
# because its materialised row had already been drained. A plain scan
# joined it when the spent-marking was added. Both are fixed by
# recording the PREPARED plan per statement handle and restoring it on
# every execute.
#
# WHY NO EXISTING GATE COVERS THIS, and the reason this file exists at
# all: isql RE-PREPARES every statement text it is given, so it never
# reuses a prepared handle and CANNOT reach the second execute. Only a
# client that caches prepared statements can - here node-firebird with
# `statementCacheSize`. A whole class of defect lives behind that door
# and the suite had no key to it.
#
# The mirror-image error is worth stating too, because a careless fix
# for the duplication would introduce it: if the exhausted CURSOR were
# kept to remember the statement had finished, a re-execute would resume
# it and return nothing. The two failures are one line apart, and this
# gate is what tells them apart - it runs each statement THREE times.
#
#   qa/serve-real-reexec.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4365}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
REAL="${FC_REAL_PORT:-3050}"
D=/tmp/fbhandson
A="$D/fc-reexec-a.fdb"
B="$D/fc-reexec-b.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not available"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (set NODE_PATH=/home/ubuntu/work)"; exit 0; }

mkdir -p "$D"
setup() {
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/$REAL:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, G INTEGER);
COMMIT;
INSERT INTO T VALUES (1,1); INSERT INTO T VALUES (2,1); INSERT INTO T VALUES (3,2);
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0; while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-reexec.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

fail=0; ran=0

# THREE runs of the same SQL text on ONE connection with the statement
# cache enabled, so the second and third reuse the prepared handle. The
# row COUNT of each run is the answer: a plan not restored gives 0 from
# run 2 on; a cursor wrongly kept alive gives the same; a correct server
# gives the same count three times.
runs() { # <db> <port> <sql>
    timeout 90 env FC_PORT="$2" FC_DB="$1" FC_Q="$3" node -e '
      process.on("uncaughtException",()=>{console.log("EXC");process.exit(0)});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey",statementCacheSize:4},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0)}
        const q=process.env.FC_Q;
        db.query(q,(e1,r1)=>{ const n1=e1?"ERR":(r1||[]).length;
          db.query(q,(e2,r2)=>{ const n2=e2?"ERR":(r2||[]).length;
            db.query(q,(e3,r3)=>{ const n3=e3?"ERR":(r3||[]).length;
              console.log(n1+"/"+n2+"/"+n3); db.detach();process.exit(0)});});});});' 2>/dev/null
}
both() { # <label> <sql>
    ran=$((ran + 1))
    e=$(runs "$B" "$REAL" "$2"); c=$(runs "$A" "$PORT" "$2")
    if [ "$c" = "$e" ] && [ -n "$e" ] && [ "${e#*/}" != "" ]; then echo "OK   $1 [$c]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}

echo "--- every plan shape, executed three times ---------------------------"
both "a plain scan"              "SELECT ID FROM T ORDER BY ID"
both "a filtered scan"           "SELECT ID FROM T WHERE ID > 1"
both "COUNT(*) - a materialised scalar" "SELECT COUNT(*) FROM T"
both "an aggregate"              "SELECT MAX(ID) M FROM T"
both "a grouped query"           "SELECT G, COUNT(*) C FROM T GROUP BY G ORDER BY G"
both "a join"                    "SELECT A.ID FROM T A JOIN T B ON A.ID=B.ID"
both "DISTINCT"                  "SELECT DISTINCT G FROM T ORDER BY G"
both "a UNION ALL"               "SELECT ID FROM T UNION ALL SELECT ID FROM T"
both "a projection expression"   "SELECT ID, ID*2 D FROM T ORDER BY ID"
both "a derived table"           "SELECT D.ID FROM (SELECT ID FROM T) D ORDER BY D.ID"
both "a windowed projection"     "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM T ORDER BY ID"
both "FIRST/SKIP"                "SELECT FIRST 2 SKIP 1 ID FROM T ORDER BY ID"
both "an empty result"           "SELECT ID FROM T WHERE ID < 0"
both "a single row"              "SELECT FIRST 1 ID FROM T ORDER BY ID"

# THE TEETH: state it directly rather than only by comparison, so the
# failure message says what happened. Run 2 and run 3 must equal run 1.
ran=$((ran + 1))
r=$(runs "$A" "$PORT" "SELECT ID FROM T ORDER BY ID")
first=${r%%/*}; rest=${r#*/}; second=${rest%%/*}; third=${rest#*/}
if [ "$first" = "$second" ] && [ "$second" = "$third" ] && [ "$first" != "0" ]; then
    echo "OK   teeth: three executes of one prepared handle all answered $first rows"
else
    echo "DIFF teeth: runs answered $r - the prepared plan is not being restored"
    fail=1
fi

echo "----------------------------------------------------------------------"
[ "$ran" -ge 15 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
