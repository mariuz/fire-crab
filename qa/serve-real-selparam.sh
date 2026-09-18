#!/bin/bash
# A CONDITIONAL TYPES ITS PARAMETER FROM ITS SIBLINGS IN THE PROJECTION
# ROUTER TOO - the same law chunk 46 measured for a DML value, in the
# SECOND router that needed it. Every shape below REFUSED here.
#
# A SELECT LIST HAS NO DESTINATION to push down, so the engine types all
# four nodes (COALESCE, NULLIF, CASE, IIF) from their non-parameter
# arguments. THAT IS A MEASURED DIFFERENCE FROM THE DML PATH, where
# NULLIF/CASE/IIF push the destination and only COALESCE reads siblings -
# copying the DML rule across would have been wrong.
#
# EVERY CELL COMPARES THE VALUE *AND* THE ANNOUNCED DESCRIBE. Chunk 46
# was caught by exactly that: cells storing identical values while
# announcing LONG len 4 against INT64 len 8.
#
# Usage: qa/serve-real-selparam.sh [port]   (default 4377)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4377}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/selparam-eng.fdb"; FC="$D/selparam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/selparam-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NM NUMERIC(9,2), N INTEGER, BI BIGINT, NN INTEGER NOT NULL, S VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 7.25, 3, 9, 5, 'ab');
INSERT INTO T VALUES (2, 1.00, 4, 8, 6, 'cd');
COMMIT;
SQL
if grep -qi error /tmp/selparam-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/selparam-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-selparam.log 2>&1 &
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
      if(e2){console.log("ERR");db.detach();process.exit(0);}
      if(!r||!r.length){console.log("(none)");db.detach();process.exit(0);}
      console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | head -1 | sed 's/^ *//' | tr -s ' '; }

# value AND describe must both match
both() {
    ran=$((ran + 1))
    local js="${3:-[1.25]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] && [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - that is a both_refuse cell]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the VALUE is right and the ANNOUNCEMENT is not - recorded, and it says
# so when that stops being true
desc_differs() {
    ran=$((ran + 1))
    local js="${3:-[1.25]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$fv" ]; then
        echo "FAIL $1 - the VALUE diverged, which this cell does not cover"
        echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`both\`"; fail=1
    else echo "OK   $1 (recorded describe gap)"; fi
}
# the engine ANSWERS and this server refuses - a DIFFERENT ROUTER
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[1.25]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS [$fv]; promote this cell"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
both_refuse() {
    ran=$((ran + 1))
    local js="${3:-[1.25]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    else echo "OK   both refuse: $1"; fi
}

echo "-- 1. COALESCE in a select list: the reconciled sibling type --"
both "COALESCE(?, 0)"        "SELECT COALESCE(?, 0) FROM T WHERE ID=1"
both "COALESCE(?, 0.5)"      "SELECT COALESCE(?, 0.5) FROM T WHERE ID=1"
both "COALESCE(?, N)"        "SELECT COALESCE(?, N) FROM T WHERE ID=1"
both "COALESCE(?, NM)"       "SELECT COALESCE(?, NM) FROM T WHERE ID=1"
both "COALESCE(0, ?) param SECOND" "SELECT COALESCE(0, ?) FROM T WHERE ID=1"
both "COALESCE(?, 0, 0.5) widest scale" "SELECT COALESCE(?, 0, 0.5) FROM T WHERE ID=1"
both "COALESCE(?, N, BI) widest rank"   "SELECT COALESCE(?, N, BI) FROM T WHERE ID=1"
both "COALESCE(?, ?, 0.5) two params"   "SELECT COALESCE(?, ?, 0.5) FROM T WHERE ID=1" '[null,1.25]'
both "COALESCE(COALESCE(?,0), 0.5) nested - node-local" "SELECT COALESCE(COALESCE(?,0), 0.5) FROM T WHERE ID=1"
both "COALESCE(?, S) all-text"          "SELECT COALESCE(?, S) FROM T WHERE ID=1" '["zz"]'

echo "-- 2. NULLIF --"
both "NULLIF(?, 0)"          "SELECT NULLIF(?, 0) FROM T WHERE ID=1"
both "NULLIF(?, 0.5)"        "SELECT NULLIF(?, 0.5) FROM T WHERE ID=1"

echo "-- 3. the OTHER clauses this router serves --"
both "WHERE COALESCE(?,0) = 1"  "SELECT ID FROM T WHERE COALESCE(?,0) = 1"
both "WHERE N = COALESCE(?,3)"  "SELECT ID FROM T WHERE N = COALESCE(?,3)" '[null]'
both "a derived table's select list" "SELECT X.C FROM (SELECT COALESCE(?,0) AS C FROM T WHERE ID=1) X"
both "a GROUPED query's select list" "SELECT COALESCE(?,0), COUNT(*) FROM T GROUP BY N"
both "the same, a typed CAST"        "SELECT CAST(? AS INTEGER), COUNT(*) FROM T GROUP BY N"

echo "-- 4. CONTROLS: shapes the ENGINE itself refuses --"
both_refuse "? alone           (-804)"  "SELECT ? FROM T WHERE ID=1"
both_refuse "? + 0             (-804)"  "SELECT ? + 0 FROM T WHERE ID=1"
both_refuse "? * 2             (-104)"  "SELECT ? * 2 FROM T WHERE ID=1"
both_refuse "COALESCE(?, ?)    (-804)"  "SELECT COALESCE(?, ?) FROM T WHERE ID=1" '[1.25,2]'
both_refuse "COALESCE(? * 2, 0)"        "SELECT COALESCE(? * 2, 0) FROM T WHERE ID=1"
both_refuse "GROUP BY ?  (bare key)"    "SELECT COUNT(*) FROM T GROUP BY ?"

echo "-- 5. CONTROLS: these already worked and must not move --"
both "CAST(? AS NUMERIC(9,2))"          "SELECT CAST(? AS NUMERIC(9,2)) FROM T WHERE ID=1"
both "COALESCE(CAST(? AS NUMERIC(9,2)), 0)" "SELECT COALESCE(CAST(? AS NUMERIC(9,2)), 0) FROM T WHERE ID=1"
both "GROUP BY N          (no param)"   "SELECT COUNT(*) FROM T GROUP BY N" '[]'
both "GROUP BY COALESCE(N,0)"           "SELECT COUNT(*) FROM T GROUP BY COALESCE(N,0)" '[]'
both "GROUP BY CAST(N AS INTEGER)"      "SELECT COUNT(*) FROM T GROUP BY CAST(N AS INTEGER)" '[]'

echo "-- 6. RECORDED: CASE and IIF answer, but announce NULLABLE --"
# The value is right; the engine announces these NOT NULL and this server
# announces Nullable. That is a DELIBERATE POLICY here, not an oversight:
# [build_expr_col_from] wraps every arm in [nullable] because "libfbclient
# renders the raw buffer instead of <null> for a NOT NULL announcement".
# Recorded rather than fought - and these shapes REFUSED outright before.
desc_differs "CASE .. THEN ? ELSE 0 END"    "SELECT CASE WHEN ID=1 THEN ? ELSE 0 END FROM T WHERE ID=1"
desc_differs "CASE .. THEN ? ELSE 0.5 END"  "SELECT CASE WHEN ID=1 THEN ? ELSE 0.5 END FROM T WHERE ID=1"
desc_differs "CASE .. THEN 0.5 ELSE ? END"  "SELECT CASE WHEN ID=2 THEN 0.5 ELSE ? END FROM T WHERE ID=1"
desc_differs "IIF(ID=1, ?, 0)"              "SELECT IIF(ID=1, ?, 0) FROM T WHERE ID=1"
desc_differs "IIF(ID=1, ?, 0.5)"            "SELECT IIF(ID=1, ?, 0.5) FROM T WHERE ID=1"
desc_differs "CASE .. THEN ? ELSE NN END"   "SELECT CASE WHEN ID=1 THEN ? ELSE NN END FROM T WHERE ID=1"
desc_differs "IIF(ID=1, ?, NN)"             "SELECT IIF(ID=1, ?, NN) FROM T WHERE ID=1"

echo "-- 7. RECORDED: DIFFERENT ROUTERS, each using resolve_expr --"
# [resolve_expr] has NO SINK to register a parameter slot into, and 110
# call sites against resolve_proj_expr's 16, so widening it is its own
# chunk rather than a side effect of this one:
#   * ORDER BY  - [parse_order_by_expr], a Fn(&str) string closure
#   * SUM(...)  - [resolve_agg_src]
#   * HAVING    - [resolve_having]
#   * GROUP BY KEY - [parse_group_by] resolves the key through
#     resolve_expr. A TYPED `CAST(? AS INTEGER)` key refuses too, which
#     is what shows this is not a sibling-typing matter at all.
eng_only "ORDER BY COALESCE(?,0)"       "SELECT ID FROM T ORDER BY COALESCE(?,0)"
eng_only "SUM(COALESCE(?,0))"           "SELECT SUM(COALESCE(?,0)) FROM T"
eng_only "HAVING COALESCE(?,0) > 0"     "SELECT COUNT(*) FROM T HAVING COALESCE(?,0) > 0"
eng_only "GROUP BY COALESCE(?,0)"       "SELECT COUNT(*) FROM T GROUP BY COALESCE(?,0)"
eng_only "GROUP BY CAST(? AS INTEGER)"  "SELECT COUNT(*) FROM T GROUP BY CAST(? AS INTEGER)"
eng_only "GROUP BY NULLIF(?,0)"         "SELECT COUNT(*) FROM T GROUP BY NULLIF(?,0)"
eng_only "GROUP BY N + CAST(? AS INT)"  "SELECT COUNT(*) FROM T GROUP BY N + CAST(? AS INTEGER)" '[1]'
# a `?` in a CONDITION is typed from the COMPARISON, which is
# [resolve_raw_cond]'s rule - and that resolver refuses parameters
eng_only "CASE WHEN ID = ? THEN 1 ELSE 0 END" "SELECT CASE WHEN ID = ? THEN 1 ELSE 0 END FROM T WHERE ID=1" '[1]'
eng_only "IIF(N = ?, 1, 0)"             "SELECT IIF(N = ?, 1, 0) FROM T WHERE ID=1" '[3]'

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN (44 on the fixing binary),
# never typed. It catches what a pass/fail tally cannot: cells SILENTLY
# DISAPPEARING - an early `exit`, a helper renamed, a `node` that stopped
# resolving - which otherwise reports a clean sweep over nothing.
if [ "$ran" -lt 44 ]; then
    echo "FAIL only $ran checks ran; 44 were measured - cells went missing"; fail=1
fi
exit $fail
