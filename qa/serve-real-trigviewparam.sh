#!/bin/bash
# A MULTIPLY CONVERTS ITS LEFT PARAMETER OPERAND AT SCALE 0 - one rule,
# and it was missing in TWO routers. Both were SILENT WRONG WRITES into a
# scaled exact column.
#
# THE RULE, measured: into a NUMERIC(9,2), `? * 2` bound 1.25 stores 2 -
# not 2.50. The DESCRIBE still announces the destination's own scale
# (SQLDA_DISPLAY prints LONG scale -2 on BOTH servers for every statement
# in this gate), so the slot PUBLISHED and the conversion APPLIED differ.
# That is why this is a VALUE bug and not a describe bug, and why a gate
# that only compared descriptors would have called it green.
#
# (A) THE TRIGGER-VIEW PATH never applied it. [plan_view_trig] hands the
#     SET / VALUES clause on as TEXT and plans a generated SELECT, so
#     [view_trig_type_params] wrapped the `?` as `CAST(? AS
#     NUMERIC(9,2))` and 1.25 * 2 stored 2.50. THE SERVER WAS ANSWERING
#     CORRECTLY - for the statement it had rewritten to: the engine also
#     gives 2.50 for that generated text. The table planner has carried
#     the rule since `e81c64f`; this path never reached it.
# (B) THE TABLE PATH missed it through a UNARY MINUS. The guard matched a
#     bare Param on the left, so `Neg(Param)` slipped past and `-? * 2`
#     stored -2.50 where the engine stores -2 - the same wrong value the
#     rule exists to prevent, one node deeper, on a PLAIN TABLE.
#
# THE CONTROLS ARE THE FIX'S BOUNDARY, each measured before it was
# written: `-(? * 2)` was already right (the negation sits ABOVE the
# multiply), `2 * -?` keeps the destination's scale, `? * -2` was already
# right, `+` `-` `/` never convert at scale 0, and an INTEGER, BIGINT or
# DOUBLE destination is untouched. A rule one shape too wide is a new
# wrong answer pointing the other way.
#
# EVERY INSERT CELL READS THE ROW IT ACTUALLY WRITES. A probe of mine
# inserted ID=2 and read WHERE ID=1: both sides agreed over a row neither
# statement had touched. A cell that measures nothing looks exactly like
# a cell that passes, which is what the `(none)` guard below is for.
#
# Usage: qa/serve-real-trigviewparam.sh [port]   (default 4373)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4373}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/tvp-eng.fdb"; FC="$D/tvp-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/tvp-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NM NUMERIC(9,2), DC DECIMAL(9,3), N INTEGER, BI BIGINT, DP DOUBLE PRECISION);
COMMIT;
INSERT INTO T VALUES (1,0.00,0.000,0,0,0);
COMMIT;
CREATE VIEW V AS SELECT ID, NM, DC, N, BI, DP FROM T;
COMMIT;
SET TERM ^ ;
CREATE TRIGGER VT FOR V BEFORE UPDATE AS
BEGIN UPDATE T SET NM = NEW.NM, DC = NEW.DC, N = NEW.N, BI = NEW.BI, DP = NEW.DP WHERE ID = OLD.ID; END^
CREATE TRIGGER VI FOR V BEFORE INSERT AS
BEGIN INSERT INTO T (ID, NM, DC, N, BI, DP) VALUES (NEW.ID, NEW.NM, NEW.DC, NEW.N, NEW.BI, NEW.DP); END^
SET TERM ; ^
COMMIT;
SQL
if grep -qi error /tmp/tvp-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/tvp-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-tvp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
      if(e2){console.log("ERR "+String(e2.message||e2).replace(/\n/g," | ").trim().slice(0,60));db.detach();process.exit(0);}
      if(!r||!r.length){console.log("(none)");db.detach();process.exit(0);}
      console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }

# <label> <stmt> <json> <column> <the ID the statement WRITES>
both() {
    ran=$((ran + 1))
    local e f
    run "$REAL" "$ENG" "$2" "$3" >/dev/null; e=$(run "$REAL" "$ENG" "SELECT $4 FROM T WHERE ID=$5" '[]')
    run "$PORT" "$FC"  "$2" "$3" >/dev/null; f=$(run "$PORT" "$FC"  "SELECT $4 FROM T WHERE ID=$5" '[]')
    if [ "$e" = CONN_ERR ] || [ "$f" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$e" = "(none)" ]; then
        echo "FAIL $1 [VACUOUS: no row $5 on the engine - the cell reads what neither statement wrote]"; fail=1
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# A RECORDED divergence that must STAY divergent - and SAYS SO when it
# stops. A cell that silently starts agreeing is a gate that has been
# overtaken without telling anyone.
differs() {
    ran=$((ran + 1))
    local e f
    run "$REAL" "$ENG" "$2" "$3" >/dev/null; e=$(run "$REAL" "$ENG" "SELECT $4 FROM T WHERE ID=$5" '[]')
    run "$PORT" "$FC"  "$2" "$3" >/dev/null; f=$(run "$PORT" "$FC"  "SELECT $4 FROM T WHERE ID=$5" '[]')
    if [ "$e" = "$f" ]; then
        echo "FAIL $1 - THE GAP IS CLOSED (both [$e]); promote this cell to \`both\`"; fail=1
    else echo "OK   $1 (recorded: eng=[$e] fc=[$f])"; fi
}

echo "-- 1. (B) the TABLE path, a NEGATED parameter --"
both "T  NM = -? * 2"      "UPDATE T SET NM = -? * 2 WHERE ID = 1"   '[1.25]'   NM 1
both "T  NM = -? * 3"      "UPDATE T SET NM = -? * 3 WHERE ID = 1"   '[1.25]'   NM 1
both "T  NM = -? * ?"      "UPDATE T SET NM = -? * ? WHERE ID = 1"   '[1.25,2]' NM 1
both "T  DC = -? * 2"      "UPDATE T SET DC = -? * 2 WHERE ID = 1"   '[1.25]'   DC 1
both "T  INSERT (-? * 2)"  "INSERT INTO T (ID, NM) VALUES (20, -? * 2)" '[1.25]' NM 20

echo "-- 2. (B) CONTROLS: the rule is the LEFT operand's, and MULTIPLY's --"
both "T  NM = -(? * 2)"    "UPDATE T SET NM = -(? * 2) WHERE ID = 1" '[1.25]'   NM 1
both "T  NM = 2 * -?"      "UPDATE T SET NM = 2 * -? WHERE ID = 1"   '[1.25]'   NM 1
both "T  NM = ? * -2"      "UPDATE T SET NM = ? * -2 WHERE ID = 1"   '[1.25]'   NM 1
both "T  NM = -? + 1"      "UPDATE T SET NM = -? + 1 WHERE ID = 1"   '[1.25]'   NM 1
both "T  NM = -? / 2"      "UPDATE T SET NM = -? / 2 WHERE ID = 1"   '[1.25]'   NM 1
both "T  NM = -?"          "UPDATE T SET NM = -? WHERE ID = 1"       '[1.25]'   NM 1
both "T  N  = -? * 2"      "UPDATE T SET N = -? * 2 WHERE ID = 1"    '[1.25]'   N  1
both "T  BI = -? * 2"      "UPDATE T SET BI = -? * 2 WHERE ID = 1"   '[1.25]'   BI 1
both "T  DP = -? * 2"      "UPDATE T SET DP = -? * 2 WHERE ID = 1"   '[1.25]'   DP 1

echo "-- 3. (A) the TRIGGER-VIEW path, UPDATE and INSERT --"
both "V  NM = ? * 2"       "UPDATE V SET NM = ? * 2 WHERE ID = 1"    '[1.25]'   NM 1
both "V  NM = ? * 2.0"     "UPDATE V SET NM = ? * 2.0 WHERE ID = 1"  '[1.25]'   NM 1
both "V  NM = ? * 3"       "UPDATE V SET NM = ? * 3 WHERE ID = 1"    '[1.25]'   NM 1
both "V  NM = ? * ?"       "UPDATE V SET NM = ? * ? WHERE ID = 1"    '[1.25,2]' NM 1
both "V  NM = (?) * 2"     "UPDATE V SET NM = (?) * 2 WHERE ID = 1"  '[1.25]'   NM 1
both "V  NM = -? * 2"      "UPDATE V SET NM = -? * 2 WHERE ID = 1"   '[1.25]'   NM 1
both "V  NM = (? * 2) + 1" "UPDATE V SET NM = (? * 2) + 1 WHERE ID = 1" '[1.25]' NM 1
both "V  NM = ? * 2 * 3"   "UPDATE V SET NM = ? * 2 * 3 WHERE ID = 1" '[1.25]'  NM 1
both "V  DC = ? * 2"       "UPDATE V SET DC = ? * 2 WHERE ID = 1"    '[1.25]'   DC 1
both "V  INSERT (? * 2)"   "INSERT INTO V (ID, NM, N) VALUES (30, ? * 2, 0)"  '[1.25]' NM 30
both "V  INSERT (-? * 2)"  "INSERT INTO V (ID, NM, N) VALUES (31, -? * 2, 0)" '[1.25]' NM 31

echo "-- 4. (A) CONTROLS: right operand, other operators, other types --"
both "V  NM = 2 * ?"       "UPDATE V SET NM = 2 * ? WHERE ID = 1"    '[1.25]'   NM 1
both "V  NM = ?"           "UPDATE V SET NM = ? WHERE ID = 1"        '[1.25]'   NM 1
both "V  NM = ? - 1"       "UPDATE V SET NM = ? - 1 WHERE ID = 1"    '[1.25]'   NM 1
both "V  NM = ? / 2"       "UPDATE V SET NM = ? / 2 WHERE ID = 1"    '[5.5]'    NM 1
both "V  N  = ? * 2"       "UPDATE V SET N = ? * 2 WHERE ID = 1"     '[1.25]'   N  1
both "V  DP = ? * 2"       "UPDATE V SET DP = ? * 2 WHERE ID = 1"    '[1.25]'   DP 1
both "V  an explicit CAST keeps its own type" \
     "UPDATE V SET NM = CAST(? AS NUMERIC(9,2)) * 2 WHERE ID = 1"    '[1.25]'   NM 1
both "V  INSERT (2 * ?)"   "INSERT INTO V (ID, NM, N) VALUES (32, 2 * ?, 0)"   '[1.25]' NM 32
both "MERGE V UPDATE SET NM = ? * 2" \
     "MERGE INTO V USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON V.ID = S.K WHEN MATCHED THEN UPDATE SET NM = ? * 2" \
     '[1.25]' NM 1

echo "-- 5. RECORDED, NOT FIXED: a COALESCE argument through the view --"
# The engine types the `?` from COALESCE's SIBLING (a plain INTEGER, so
# 1.25 becomes 1 and the product is 2). Reproducing that in the GENERATED
# SELECT means typing a bare `?` from a sibling, which this server cannot
# do - it errors on that text outright. Recorded rather than half-fixed:
# the table path already answers this shape correctly.
differs "V  COALESCE(?,0) * 2" "UPDATE V SET NM = COALESCE(?,0) * 2 WHERE ID = 1" '[1.25]' NM 1

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN (35 on the fixing binary),
# never typed. It catches what a pass/fail tally cannot: cells SILENTLY
# DISAPPEARING - an early `exit`, a helper renamed, a `node` that stopped
# resolving - which otherwise reports a clean sweep over nothing.
if [ "$ran" -lt 35 ]; then
    echo "FAIL only $ran checks ran; 35 were measured - cells went missing"; fail=1
fi
exit $fail
