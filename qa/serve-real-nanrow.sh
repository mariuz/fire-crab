#!/bin/bash
# A NaN THAT IS A ROW VALUE - the same question as `serve-real-nanparam.sh`
# asks of a bound parameter, one site deeper, where `value_cmp`'s
# approximate arm ended in `partial_cmp().unwrap_or(Equal)` and so made a
# NaN EQUAL TO EVERYTHING.
#
# THE RULE, which ~200 measured predicate cells fit (2026-09-20, over
# stored NaN / +-Infinity / NULL rows on a heap twin and an indexed twin):
#
#   * THE RESULT IS NEVER "EQUAL", so `=` is FALSE and `<>` is TRUE - and
#     it is TWO-VALUED, not UNKNOWN: `NOT (D >= 0.0e0)` is TRUE.  `D = D`
#     is FALSE on a NaN row and `D IS NOT DISTINCT FROM D` is FALSE too.
#   * ONE OPERAND IS THE **PRIMARY** AND IT IS THE LESSER.  The primary is
#     the operand of HIGHER TYPE RANK - DOUBLE > FLOAT > exact - and on a
#     TIE it is THE FIRST-WRITTEN one.  So BOTH spellings of `<` are TRUE
#     between two DOUBLEs (`D < D2` and `D2 < D` on the same NaN row), and
#     a NaN in a FLOAT column meeting a DOUBLE is the GREATER operand.
#
# THE RANK CLAUSE IS WHAT A FIRST CUT GOT WRONG by carrying the PARAMETER
# law over unchanged: "against a FLOAT side the NaN is always the lesser"
# predicts `FL > 0.0e0` FALSE, and the engine says TRUE.
#
# WHAT THIS GATE DOES NOT CLAIM.  A NaN has FOUR surfaces and this chunk
# fixes ONE of them - the EQUALITY-BASED one (predicate truth, join ON).
# The others are measured and RECORDED here, not fixed:
#   * SORT PLACEMENT is IEEE-754 totalOrder INCLUDING THE SIGN BIT -
#     `-NaN < -Inf < finite < +Inf < +NaN` - which no "greatest" or
#     "least" rule can produce;
#   * DISTINCT dedups BY THAT SORT KEY, so two +NaN rows COLLAPSE (7
#     distinct from 8 rows);
#   * GROUP BY uses EQUALITY instead, so the same two rows do NOT
#     collapse (8 groups from 8 rows) - the engine giving two different
#     answers for DISTINCT and GROUP BY over one column on one set of
#     rows is the sharpest fact in the round;
#   * a UNIQUE/PRIMARY KEY follows the EQUALITY rule and accepts a SECOND
#     NaN while still raising for a duplicate 1.5.
#
# THE ROWS CANNOT BE WRITTEN IN SQL: `CAST('nan' AS DOUBLE PRECISION)` is
# a 22018 conversion error here, `1e308*10` and `EXP(1000)` raise 22003,
# `0e0/0e0` raises 22012.  A BOUND PARAMETER is the only way in, so the
# schema goes in through isql, the ROWS through node against the LIVE
# ENGINE, and the engine's own file is copied to this server's side.  The
# loader carries a SENTINEL: 8 rows per table and two of them really
# rendering `nan`, or the run stops.
#
# Usage: qa/serve-real-nanrow.sh [port]   (default 4445)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4445}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nanrow-eng.fdb"; FC="$D/nanrow-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
# THE ROWS CANNOT BE WRITTEN IN SQL.  Measured first, because it decides
# the whole fixture: `CAST('nan' AS DOUBLE PRECISION)` is a 22018
# conversion error on this engine, `1e308*10` and `EXP(1000)` raise 22003,
# and `0e0/0e0` raises 22012 - THE ONLY WAY A NON-FINITE GETS INTO A
# COLUMN IS A BOUND PARAMETER.  So the schema goes in through isql and the
# ROWS go in through node, against the LIVE ENGINE, and the engine's own
# file is then copied to this server's side.
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/nanrow-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE M  (ID INTEGER, D DOUBLE PRECISION, D2 DOUBLE PRECISION, FL FLOAT, N INTEGER, NM NUMERIC(9,2));
CREATE TABLE MI (ID INTEGER NOT NULL PRIMARY KEY, D DOUBLE PRECISION, D2 DOUBLE PRECISION, FL FLOAT, N INTEGER, NM NUMERIC(9,2));
CREATE TABLE W  (ID INTEGER, D DOUBLE PRECISION, N INTEGER);
/* a PRIMARY KEY on a DOUBLE - key equality, not predicate truth */
CREATE TABLE UD (D DOUBLE PRECISION NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
CREATE INDEX MI_D  ON MI (D);
CREATE INDEX MI_FL ON MI (FL);
CREATE INDEX MI_N  ON MI (N);
COMMIT;
SQL
if grep -qi error /tmp/nanrow-build.log; then
    echo "FAIL building the schema:"; sed 's/^/     /' /tmp/nanrow-build.log; exit 1
fi
LOADJS=$(mktemp /tmp/nanrow-load-XXXX.js)
cat > "$LOADJS" <<'JS'
const F=require("node-firebird");
const NN=NaN, PI=Infinity, MI=-Infinity;
//        ID    D     D2    FL   N     NM
const R=[[1,   NN,   NN,   NN,   1,  1.0],
         [2,   PI,  1.0,   PI,   2,  2.0],
         [3,   MI, -1.0,   MI,   3,  3.0],
         [4, null, null, null, null, null],
         [5,  1.5,  2.5,  1.5,   5,  5.0],
         [6, -2.5,   NN, -2.5,   6,  6.0],
         [7,  0.0,  0.0,  0.0,   0,  0.0],
         [8,   NN,  1.5,   NN,   8,  8.0]];
const jobs=[];
for(const t of ["M","MI"]) for(const r of R) jobs.push(["INSERT INTO "+t+" (ID,D,D2,FL,N,NM) VALUES (?,?,?,?,?,?)",r]);
for(const r of R) jobs.push(["INSERT INTO W (ID,D,N) VALUES (?,?,?)",[r[0],r[1],r[4]]]);
for(const u of [[NN,1],[1.5,2],[PI,3],[MI,4],[0.0,5]]) jobs.push(["INSERT INTO UD (D,V) VALUES (?,?)",u]);
F.attach({host:"127.0.0.1",port:+process.argv[2],database:process.argv[3],user:"SYSDBA",password:"masterkey"},(e,db)=>{
 if(e){console.log("LOAD ATTACH FAIL "+e.message);process.exit(1);}
 let i=0,bad=0;
 const step=()=>{
  if(i>=jobs.length){
   // SENTINEL: the rows must be there AND the NaNs must really be NaN -
   // a fixture that silently failed makes every cell compare empty with
   // empty and print OK.
   db.query("SELECT (SELECT COUNT(*) FROM M) CM,(SELECT COUNT(*) FROM MI) CMI,(SELECT COUNT(*) FROM W) CW,(SELECT COUNT(*) FROM UD) CU,(SELECT COUNT(*) FROM M WHERE CAST(D AS VARCHAR(20))='nan') NANM FROM RDB$DATABASE",[],(e2,r)=>{
     if(e2){console.log("SENTINEL FAIL "+e2.message);process.exit(1);}
     const s=r[0];
     console.log("errors="+bad+" sentinel="+JSON.stringify(s));
     if(bad||s.CM!=8||s.CMI!=8||s.CW!=8||s.CU!=5||s.NANM!=2){console.log("LOAD SENTINEL MISMATCH");process.exit(1);}
     db.detach();process.exit(0);});
   return;
  }
  const [q,p]=jobs[i++];
  db.query(q,p,(e2)=>{ if(e2){bad++;} step(); });
 }; step();
});
JS
if ! node "$LOADJS" "$REAL" "$ENG"; then
    echo "FAIL loading the non-finite rows through a parameter"; rm -f "$LOADJS"; exit 1
fi
rm -f "$LOADJS"
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

SRVLOG="/tmp/fc-serve-nanrow-$PORT.log"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$SRVLOG" 2>&1 &
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
LOST='const lost=e=>/was lost|ECONNRESET|EPIPE|Connection is closed|socket hang up/i.test(String((e&&e.message)||e));'
RV='const rv=v=>v==="#NaN"?NaN:v==="#Inf"?Infinity:v==="#-Inf"?-Infinity:v;'
FMT='const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":v).join()).join(";");'
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e "$LOST$RV$FMT"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P).map(rv),(e2,r)=>{
      if(e2){if(lost(e2)){console.log("CONN_ERR");process.exit(1);}console.log("ERR");db.detach();process.exit(0);}
      console.log(fmt(r));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
qtx() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e "$LOST$RV$FMT"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      if(et){console.log("CONN_ERR");process.exit(1);}
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P).map(rv),(e2,r)=>{
        if(e2&&lost(e2)){console.log("CONN_ERR");process.exit(1);}
        const dml=e2?"ERR":fmt(r);
        tr.query(process.env.FC_RB,[],(e3,r2)=>{
          if(e3&&lost(e3)){console.log("CONN_ERR");process.exit(1);}
          const rb=e3?"ERR":fmt(r2);
          tr.rollback(()=>{console.log("dml="+dml+" rb="+rb);db.detach();process.exit(0);});
        });
      });
    });
  });' 2>/dev/null; }
runtx() { local n=0 r; while [ $n -lt 8 ]; do r=$(qtx "$1" "$2" "$3" "$4" "$5")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }

# the value AND the whole describe must match
both() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] && [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - that is a both_refuse cell]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the VALUE is right and the ANNOUNCEMENT is not - recorded, self-expiring
desc_differs() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$fv" ]; then
        echo "FAIL $1 - the VALUE diverged, which this cell does not cover"
        echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`both\`"; fail=1
    else echo "OK   $1 (recorded describe gap)"; fi
}
# the engine ANSWERS and this server refuses - here always because the
# ENGINE ITSELF HAS TWO ANSWERS and this server will not pick one
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER ANSWERS [$fv] where it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
both_refuse() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    else echo "OK   both refuse: $1"; fi
}
# a DML + read-back in a rolled-back transaction
dml_rb() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (the RETURNING rows or the read-back)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 [$ev] (rolled back)"; fi
}
# the engine WRITES and this server refuses - its rows must be untouched
dml_rb_eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then
        echo "FAIL $1 - the ENGINE refused the DML [$ev]; the boundary moved"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then
        echo "FAIL $1 - THIS SERVER PERFORMED THE DML [$fv]; it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}


# BOTH servers RAISE the DML inside the rolled-back transaction and the
# read-backs agree - the rows are untouched on both.  A duplicate key is
# supposed to raise, so `dml_rb` (which fails when the ENGINE refuses)
# cannot express it.
dml_rb_both_err() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not raise [$ev]"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then echo "FAIL $1 - THIS server did not raise [$fv]"; fail=1
    elif [ "${ev#*rb=}" != "${fv#*rb=}" ]; then
        echo "FAIL $1 (the read-back after the raise differs)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 [$ev] (both raise; rolled back)"; fi
}

# A RECORDED DIVERGENCE, pinned on BOTH sides: the engine's answer and
# this server's, each stated.  It fails when they start AGREEING (promote
# it), when either side moves, and when either side refuses.
divergence() { # <label> <sql> <json> <engine-answer> <this-server-answer>
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] || [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: a side refused] eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ev" = "$fv" ]; then
        echo "FAIL $1 - THE TWO NOW AGREE [$ev]; promote this cell to \`both\`"; fail=1
    elif [ "$ev" != "$4" ] || [ "$fv" != "$5" ]; then
        echo "FAIL $1 - a recorded answer MOVED"
        echo "     engine: want [$4] got [$ev]"; echo "     fcwire: want [$5] got [$fv]"; fail=1
    else echo "OK   recorded divergence: $1 (engine [$ev], this server [$fv])"; fi
}

echo "-- 1. THE EQUALITY RULE: a NaN is never equal, not even to itself --"
both             "1 WHERE D = D - the NaN rows 1 and 8 drop out, and so does the NULL row 4 (engine 2;3;5;6;7)" "SELECT ID FROM M WHERE D = D ORDER BY ID" '[]'
both             "1 TI WHERE D = D - indexed (engine 2;3;5;6;7)" "SELECT ID FROM MI WHERE D = D ORDER BY ID" '[]'
both             "1 WHERE D <> D - and its complement is TRUE, two-valued (engine 1;8)" "SELECT ID FROM M WHERE D <> D ORDER BY ID" '[]'
both             "1 WHERE D IS NOT DISTINCT FROM D - even the identity predicate says distinct (engine 2;3;4;5;6;7)" "SELECT ID FROM M WHERE D IS NOT DISTINCT FROM D ORDER BY ID" '[]'
both             "1 WHERE D IS DISTINCT FROM D (engine 1;8)" "SELECT ID FROM M WHERE D IS DISTINCT FROM D ORDER BY ID" '[]'
both             "1 a self-join ON A.D = B.D - only the non-NaN rows pair with themselves (engine 2,2;3,3;5,5;6,6;7,7)" "SELECT A.ID, B.ID FROM M A JOIN M B ON A.D = B.D ORDER BY A.ID, B.ID" '[]'
both             "1 FL = FL - the same on a FLOAT column (engine 2;3;5;6;7)" "SELECT ID FROM M WHERE FL = FL ORDER BY ID" '[]'

echo "-- 2. THE PRIMARY IS THE LESSER, and rank beats the writing order --"
# Between two DOUBLEs it is a TIE and the FIRST-WRITTEN wins, which is
# why BOTH spellings of `<` are TRUE on the same row.
both             "2 D < D2 - row 6 holds a finite D and a NaN D2 (engine 1;6;8)" "SELECT ID FROM M WHERE D < D2 ORDER BY ID" '[]'
both             "2 D2 < D - the SAME question written the other way, also TRUE (engine 1;6;8)" "SELECT ID FROM M WHERE D2 < D ORDER BY ID" '[]'
both             "2 D > D2 - and both `>` spellings are FALSE (engine (none))" "SELECT ID FROM M WHERE D > D2 ORDER BY ID" '[]'
both             "2 D2 > D (engine (none))" "SELECT ID FROM M WHERE D2 > D ORDER BY ID" '[]'
both             "2 D < D - a column against itself (engine 1;8)" "SELECT ID FROM M WHERE D < D ORDER BY ID" '[]'
both             "2 D > D (engine (none))" "SELECT ID FROM M WHERE D > D ORDER BY ID" '[]'
# ...and RANK OUTRANKS the order: a NaN in a FLOAT column meeting a
# DOUBLE is the GREATER operand.  This is the clause the parameter law
# got wrong.
both             "2 FL > 0.0e0 - a FLOAT NaN against a DOUBLE literal is GREATER (engine 1;2;8)" "SELECT ID FROM M WHERE FL > 0.0e0 ORDER BY ID" '[]'
both             "2 FL < 0.0e0 (engine 3;6)" "SELECT ID FROM M WHERE FL < 0.0e0 ORDER BY ID" '[]'
both             "2 D > 0 - against an EXACT literal the NaN is the LESSER (engine 2;5)" "SELECT ID FROM M WHERE D > 0 ORDER BY ID" '[]'
both             "2 D < 0 - ...so the NaN rows come in here (engine 1;3;6;8)" "SELECT ID FROM M WHERE D < 0 ORDER BY ID" '[]'
both             "2 0 > D - the exact side written first (engine 1;3;6;8)" "SELECT ID FROM M WHERE 0 > D ORDER BY ID" '[]'
both             "2 D < N - against an exact COLUMN (engine 1;3;6;8)" "SELECT ID FROM M WHERE D < N ORDER BY ID" '[]'
both             "2 N > D (engine 1;3;6;8)" "SELECT ID FROM M WHERE N > D ORDER BY ID" '[]'
both             "2 NOT (D >= 0.0e0) - TWO-VALUED: the NaN rows come back, they are not UNKNOWN (engine 1;3;6;8)" "SELECT ID FROM M WHERE NOT (D >= 0.0e0) ORDER BY ID" '[]'

echo "-- 3. CONTROLS: the same statements over the rows that are not NaN --"
both             "3 CONTROL D > 1.0e0 - an ordinary comparison (engine 2;5)" "SELECT ID FROM M WHERE D > 1.0e0 ORDER BY ID" '[]'
both             "3 CONTROL D IS NULL - the NULL row is still its own thing (engine 4)" "SELECT ID FROM M WHERE D IS NULL ORDER BY ID" '[]'
both             "3 CONTROL N = N - an exact column has no NaN to find (engine 1;2;3;5;6;7;8)" "SELECT ID FROM M WHERE N = N ORDER BY ID" '[]'
both             "3 CONTROL NM = NM - a scaled column (engine 1;2;3;5;6;7;8)" "SELECT ID FROM M WHERE NM = NM ORDER BY ID" '[]'
both             "3 TEETH D = 1.5e0 - a plain equality still finds its ONE row; the previous binary matched the two NaN rows as well, because a NaN equalled everything (engine 5)" "SELECT ID FROM M WHERE D = 1.5e0 ORDER BY ID" '[]'
both             "3 CONTROL D > 0.0e0 AND D < 9e99 - the infinities behave (engine 5)" "SELECT ID FROM M WHERE D > 0.0e0 AND D < 9e99 ORDER BY ID" '[]'

echo "-- 3b. THE ACCESS-PATH SPLIT IS ON THE **UPPER** BOUND, and it is this chunk's price --"
# The NaN's INDEX KEY sorts ABOVE +Infinity (the ORDER BY order), so a
# range with a STOP bound (`<`, `<=`) DROPS it while a range with only a
# START bound keeps it.  Measured with the PLAN confirmed, and it survives
# a CTE, a derived table, a UNION leg, a view and into DML.
#
# THE TRADE, stated plainly.  Before this chunk the heap answer was WRONG
# (a NaN compared equal to everything, so `D < 0` gave 3;6) and the
# INDEXED answer was right BY COINCIDENCE.  Now the heap is right and the
# indexed twin is not, because this server scans where the engine ranges
# and nothing at evaluation time can see which.  Everything else - the
# whole equality family, and both bounds written the other way round - is
# now right on BOTH paths.  The two cells below are the price, pinned.
both             "3b M WHERE D < 0 - the HEAP, which this chunk fixes (engine 1;3;6;8)" "SELECT ID FROM M WHERE D < 0 ORDER BY ID" '[]'
both             "3b M WHERE D <= 0 - the heap (engine 1;3;6;7;8)" "SELECT ID FROM M WHERE D <= 0 ORDER BY ID" '[]'
divergence       "3b MI WHERE D < 0 - the INDEXED twin: the engine\'s range stops below the NaN" "SELECT ID FROM MI WHERE D < 0 ORDER BY ID" '[]' "3;6" "1;3;6;8"
divergence       "3b MI WHERE D <= 0 - the same at the inclusive bound" "SELECT ID FROM MI WHERE D <= 0 ORDER BY ID" '[]' "3;6;7" "1;3;6;7;8"
# ...and the LOWER bound does NOT split, on either path - which is what
# says the mechanism is the STOP bound and not the index as such.
both             "3b M WHERE 0.0e0 < D - a START bound keeps the NaN (engine 1;2;5;8)" "SELECT ID FROM M WHERE 0.0e0 < D ORDER BY ID" '[]'
both             "3b MI WHERE 0.0e0 < D - indexed, the SAME answer (engine 1;2;5;8)" "SELECT ID FROM MI WHERE 0.0e0 < D ORDER BY ID" '[]'
both             "3b M WHERE D > 0 (engine 2;5)" "SELECT ID FROM M WHERE D > 0 ORDER BY ID" '[]'
both             "3b MI WHERE D > 0 - indexed, the same (engine 2;5)" "SELECT ID FROM MI WHERE D > 0 ORDER BY ID" '[]'
both             "3b MI WHERE D = D - and the EQUALITY rule is path-independent (engine 2;3;5;6;7)" "SELECT ID FROM MI WHERE D = D ORDER BY ID" '[]'

echo "-- 3c. KEY EQUALITY FOLLOWS THE SAME RULE: a NaN key never conflicts --"
# A UNIQUE/PRIMARY KEY asks the SAME question the predicate does, and gets
# the same answer: a NaN is not equal to itself, so a PK on a DOUBLE
# accepts a SECOND NaN.  Measured on the live engine, which then holds two
# NaN keys, while a duplicate 1.5 or a duplicate `inf` STILL raises.
#
# The mechanism is worth stating because it is not the comparator: the
# index KEY BYTES of two NaNs are IDENTICAL (`double_key` is an
# order-preserving transform), so the B-tree's own entry-level check calls
# the second a duplicate.  A NaN key is therefore EXEMPT from uniqueness -
# for a DIFFERENT reason from an all-NULL key, so it travels as its own
# flag ([key_carries_nan]).
dml_rb           "3c INSERT INTO UD VALUES (?, 9) [NaN] - a SECOND NaN key is accepted (engine dml=(none) rb=1,nan;2,1.500000000000000;3,inf;4,-inf;5,0.000000000000000;9,nan)" "INSERT INTO UD (D, V) VALUES (?, 9)" '["#NaN"]' "SELECT V AS A, CAST(D AS VARCHAR(25)) AS B FROM UD ORDER BY V"
dml_rb_both_err  "3c CONTROL a duplicate 1.5 STILL raises (engine dml=ERR, the table unchanged)" "INSERT INTO UD (D, V) VALUES (?, 9)" '[1.5]' "SELECT V AS A, CAST(D AS VARCHAR(25)) AS B FROM UD ORDER BY V"
dml_rb_both_err  "3c CONTROL a duplicate +Inf STILL raises - an infinity is an ordinary value (engine dml=ERR)" "INSERT INTO UD (D, V) VALUES (?, 9)" '["#Inf"]' "SELECT V AS A, CAST(D AS VARCHAR(25)) AS B FROM UD ORDER BY V"
dml_rb           "3c CONTROL a NEW finite key inserts (engine dml=(none) rb=...;9,7.500000000000000)" "INSERT INTO UD (D, V) VALUES (?, 9)" '[7.5]' "SELECT V AS A, CAST(D AS VARCHAR(25)) AS B FROM UD ORDER BY V"

echo "-- 4. WHAT THIS CHUNK DOES NOT FIX, pinned so it cannot be mistaken for agreement --"
# Each of these is a DIFFERENT rule from the equality one above, each
# measured, and each still divergent here.  A wrong answer cannot be a
# green cell, so they are recorded with BOTH answers rather than hidden.
divergence       "4 ORDER BY D - the engine sorts by IEEE totalOrder and puts +NaN ABOVE +Inf; this server does not" "SELECT ID FROM M ORDER BY D, ID" '[]' "4;3;6;7;5;2;1;8" "4;1;3;6;7;5;2;8"
divergence       "4 COUNT of DISTINCT D - the engine dedups BY THE SORT KEY, so the two +NaN rows COLLAPSE" "SELECT COUNT(*) A FROM (SELECT DISTINCT D FROM M) X" '[]' "7" "2"
divergence       "4 COUNT of the GROUP BY groups - and GROUP BY uses EQUALITY instead, so the same two rows do NOT collapse" "SELECT COUNT(*) A FROM (SELECT D FROM M GROUP BY D) X" '[]' "8" "2"

# the server's stderr log is the ONE place a PANIC shows
panic_free() {
    ran=$((ran + 1))
    local n
    n=$(grep -ac 'panicked at' "$SRVLOG" 2>/dev/null); [ -n "$n" ] || n=0
    if ! kill -0 $srv 2>/dev/null; then
        echo "FAIL the server DIED during the run"; fail=1
    elif [ "$n" != 0 ]; then
        echo "FAIL the server PANICKED $n time(s) - an ERR above may be a crash, not a refusal"
        grep -a 'panicked at' "$SRVLOG" | head -5 | sed 's/^/     /'; fail=1
    else echo "OK   no panic in $SRVLOG and the server is still up"; fi
}
panic_free

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN, never typed.
if [ "$ran" -lt 44 ]; then
    echo "FAIL only $ran checks ran; 44 were measured - cells went missing"; fail=1
fi
exit $fail
