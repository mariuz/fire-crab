#!/bin/bash
# SELECT FROM <procedure> over the wire, served BLR-FIRST through
# fire-crab-exe. The server now tries the stored RDB$PROCEDURE_BLR -
# the same bytes fcdsql matches byte-for-byte and the engine itself
# executes - and only falls back to the source interpreter outside
# the executor's surface. The payoff: procedure bodies the
# interpreter NEVER learned now serve over the wire - window
# functions, frames, LAG, quantified subqueries, outer-join chains -
# and every answer must equal the ENGINE running the same procedure.
#
#   qa/serve-real-exeproc.sh [port]
#
# Builds its own scratch database THROUGH THE ENGINE (procedures and
# their BLR are engine-compiled; fire-crab executes the stored bytes).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4097}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/exeproc.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$DB"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(10));
CREATE TABLE U2 (UID INTEGER, UA INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 3, 'aa');
INSERT INTO T VALUES (2, 8, 'bb');
INSERT INTO T VALUES (3, NULL, 'cc');
INSERT INTO T VALUES (4, 12, NULL);
INSERT INTO T VALUES (5, 8, 'ee');
INSERT INTO U2 VALUES (1, 100);
INSERT INTO U2 VALUES (2, 200);
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE PW1 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, SUM(AMT) OVER (ORDER BY ID) FROM T INTO :R1, :R2 DO SUSPEND; END^
CREATE PROCEDURE PW2 RETURNS (R1 INTEGER, R2 INTEGER, R3 INTEGER) AS BEGIN FOR SELECT AMT, RANK() OVER (ORDER BY AMT), DENSE_RANK() OVER (ORDER BY AMT) FROM T INTO :R1, :R2, :R3 DO SUSPEND; END^
CREATE PROCEDURE PW3 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, LAG(AMT) OVER (ORDER BY ID) FROM T INTO :R1, :R2 DO SUSPEND; END^
CREATE PROCEDURE PW4 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, SUM(AMT) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM T INTO :R1, :R2 DO SUSPEND; END^
CREATE PROCEDURE PW5 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID) INTO :R1 DO SUSPEND; END^
CREATE PROCEDURE PW6 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT > :P1 ORDER BY ID INTO :R1 DO SUSPEND; END^
CREATE PROCEDURE PW7 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A.ID, B.UA FROM T A FULL JOIN U2 B ON A.ID = B.UID ORDER BY A.ID INTO :R1, :R2 DO SUSPEND; END^
SET TERM ; ^
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exeproc.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <query>
    got=$(node_run "$2")
    want=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/|/g' | grep -v '^$'
SET HEADING OFF;
$2;
SQL
)
    if [ "$got" = "$want" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $(printf '%s' "$want" | tr '\n' ' ')"
        echo "     fcwire: $(printf '%s' "$got" | tr '\n' ' ')"
        fail=1
    fi
}

check "running SUM window over the wire"        "SELECT * FROM PW1"
check "RANK + DENSE_RANK over the wire"         "SELECT * FROM PW2"
check "LAG over the wire"                       "SELECT * FROM PW3"
check "ROWS BETWEEN frame over the wire"        "SELECT * FROM PW4"
check "correlated EXISTS over the wire"         "SELECT * FROM PW5"
check "parameterized procedure over the wire"   "SELECT * FROM PW6(5)"
check "FULL JOIN over the wire"                 "SELECT * FROM PW7"

exit $fail
