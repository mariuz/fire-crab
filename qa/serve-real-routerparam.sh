#!/bin/bash
# A TYPED OR SIBLING-TYPED PARAMETER IN THE FOUR REMAINING ROUTERS - the
# aggregate argument, the GROUP BY key, an ORDER BY expression and a
# HAVING side. Each resolved through resolve_expr, which refuses every
# `?`, so SUM(CAST(? AS INTEGER)), GROUP BY CAST(? AS INTEGER), ORDER BY
# COALESCE(?, ID) and HAVING COALESCE(?, 0) > 0 all refused while the
# engine answers every one. The typing law is the projection's (chunks
# 46/47); what each router lacked was a SINK to register the slot into,
# the NUMBERING of its `?` in the statement's text order, and the
# execute-time BINDING of aggregate sources, group keys and order keys.
#
# MEASURED NUMBERING (the engine's input SQLDA): select list - an
# aggregate's argument in place - then WHERE, GROUP BY, HAVING, ORDER BY.
# Several cells bind two or three parameters of DIFFERENT values, so a
# swapped slot is a different answer, never a coincidental match.
#
# EVERY `both` CELL COMPARES THE VALUE *AND* THE WHOLE DESCRIBE (every
# input and output slot), because a slot can carry the right value under
# the wrong announcement.
#
# Usage: qa/serve-real-routerparam.sh [port]   (default 4381)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4381}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/routerparam-eng.fdb"; FC="$D/routerparam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/routerparam-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NM NUMERIC(9,2), N INTEGER, BI BIGINT, S VARCHAR(10), D DOUBLE PRECISION);
COMMIT;
INSERT INTO T VALUES (1, 7.25, 3, 9, 'ab', 1.5);
INSERT INTO T VALUES (2, 1.00, 4, 8, 'cd', 2.5);
INSERT INTO T VALUES (3, 2.50, 4, 7, 'ef', 3.5);
COMMIT;
SQL
if grep -qi error /tmp/routerparam-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/routerparam-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-routerparam.log 2>&1 &
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
# EVERY slot of the describe, input and output, on one line
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }

# value AND describe must both match
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
# the VALUE is right and the ANNOUNCEMENT is not - recorded, and it says
# so when that stops being true
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
# the engine ANSWERS and this server refuses - a recorded boundary
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS [$fv]; promote this cell"; fail=1
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

echo "-- 1. the AGGREGATE ARGUMENT --"
both "SUM(CAST(? AS INTEGER))"            "SELECT SUM(CAST(? AS INTEGER)) FROM T" '[2]'
both "SUM(ID * CAST(? AS INTEGER))"       "SELECT SUM(ID * CAST(? AS INTEGER)) FROM T" '[2]'
both "SUM(COALESCE(?, 0))"                "SELECT SUM(COALESCE(?, 0)) FROM T" '[2]'
both "SUM(COALESCE(?, N)) bound NULL"     "SELECT SUM(COALESCE(?, N)) FROM T" '[null]'
both "MAX(CAST(? AS INTEGER))"            "SELECT MAX(CAST(? AS INTEGER)) FROM T" '[2]'
both "COUNT(CAST(? AS INTEGER))"          "SELECT COUNT(CAST(? AS INTEGER)) FROM T" '[2]'
both "COUNT(CAST(? AS INTEGER)) bound NULL counts 0" "SELECT COUNT(CAST(? AS INTEGER)) FROM T" '[null]'
both "COUNT(DISTINCT CAST(? AS INTEGER))" "SELECT COUNT(DISTINCT CAST(? AS INTEGER)) FROM T" '[2]'
both "SUM(CASE WHEN .. THEN ? ELSE N END)" "SELECT SUM(CASE WHEN ID=1 THEN ? ELSE N END) FROM T" '[5]'
both "AVG(CAST(? AS NUMERIC(9,2)))"       "SELECT AVG(CAST(? AS NUMERIC(9,2))) FROM T" '[1.25]'
both "SUM(NM * CAST(? AS INTEGER))"       "SELECT SUM(NM * CAST(? AS INTEGER)) FROM T" '[2]'
both "MIN(CAST(? AS VARCHAR(3)))"         "SELECT MIN(CAST(? AS VARCHAR(3))) FROM T" '["ab"]'
both "SUM(ID) + CAST(? AS INTEGER) - an expression OVER the fold" "SELECT SUM(ID) + CAST(? AS INTEGER) FROM T" '[2]'
both "grouped: N, SUM(CAST(? AS INTEGER))" "SELECT N, SUM(CAST(? AS INTEGER)) FROM T GROUP BY N ORDER BY N" '[2]'
both "over a derived table"               "SELECT SUM(CAST(? AS INTEGER)) FROM (SELECT ID FROM T) X" '[2]'
both "over a join"                        "SELECT SUM(CAST(? AS INTEGER)) FROM T A JOIN T B ON A.ID = B.ID" '[2]'
both "NUMBERING: the argument numbers IN PLACE between its neighbours" \
     "SELECT CAST(? AS SMALLINT) A, SUM(CAST(? AS INTEGER)) B, CAST(? AS BIGINT) C FROM T" '[1,2,3]'
# chunk 47's recorded gap, on the INPUT slot here: the engine announces
# the `?` NOT NULL beside a NOT NULL sibling, this server always Nullable
desc_differs "SUM(IIF(ID=1, ?, 0)) - the IIF NOT NULL announcement" "SELECT SUM(IIF(ID=1, ?, 0)) FROM T" '[5]'

echo "-- 2. an ORDER BY EXPRESSION --"
both "ORDER BY CAST(? AS INTEGER) (a constant key)" "SELECT ID FROM T ORDER BY CAST(? AS INTEGER)" '[2]'
both "ORDER BY COALESCE(?, ID)"           "SELECT ID FROM T ORDER BY COALESCE(?, ID)" '[null]'
both "ORDER BY COALESCE(?, ID) DESC"      "SELECT ID FROM T ORDER BY COALESCE(?, ID) DESC" '[null]'
both "ORDER BY ID * CAST(? AS INTEGER) bound -1" "SELECT ID FROM T ORDER BY ID * CAST(? AS INTEGER)" '[-1]'
both "NUMBERING: the WHERE's slot before the ORDER BY's" \
     "SELECT ID FROM T WHERE ID > CAST(? AS SMALLINT) ORDER BY ID * CAST(? AS INTEGER)" '[1,-1]'
both "grouped: ORDER BY SUM(ID * CAST(? AS INTEGER)) DESC" \
     "SELECT N, COUNT(*) FROM T GROUP BY N ORDER BY SUM(ID * CAST(? AS INTEGER)) DESC" '[-1]'
both "a join's ORDER BY COALESCE(?, A.ID) DESC" \
     "SELECT A.ID FROM T A JOIN T B ON A.ID = B.ID ORDER BY COALESCE(?, A.ID) DESC" '[null]'
both "a derived table's ORDER BY COALESCE(?, X.ID) DESC" \
     "SELECT X.ID FROM (SELECT ID FROM T) X ORDER BY COALESCE(?, X.ID) DESC" '[null]'
both "under DISTINCT"                     "SELECT DISTINCT N FROM T ORDER BY CAST(? AS INTEGER)" '[1]'
both "under FIRST"                        "SELECT FIRST 2 ID FROM T ORDER BY COALESCE(?, ID) DESC" '[null]'

echo "-- 3. a HAVING side --"
both "HAVING SUM(CAST(? AS INTEGER)) > 3" "SELECT N FROM T GROUP BY N HAVING SUM(CAST(? AS INTEGER)) > 3" '[2]'
both "HAVING SUM(ID * CAST(? AS INTEGER)) > 2" "SELECT N FROM T GROUP BY N HAVING SUM(ID * CAST(? AS INTEGER)) > 2" '[1]'
both "HAVING COUNT(CAST(? AS INTEGER)) > 1" "SELECT N FROM T GROUP BY N HAVING COUNT(CAST(? AS INTEGER)) > 1" '[7]'
both "HAVING COALESCE(?,0) > 0 - true"    "SELECT COUNT(*) FROM T HAVING COALESCE(?,0) > 0" '[1]'
both "HAVING COALESCE(?,0) > 0 - false"   "SELECT COUNT(*) FROM T HAVING COALESCE(?,0) > 0" '[0]'
both "HAVING SUM(ID) > COALESCE(?, 0) + 3" "SELECT N FROM T GROUP BY N HAVING SUM(ID) > COALESCE(?, 0) + 3" '[null]'
both "NUMBERING: HAVING's slot before ORDER BY's (swapped binds answer nothing)" \
     "SELECT N FROM T GROUP BY N HAVING SUM(CAST(? AS SMALLINT)) > 3 ORDER BY SUM(ID * CAST(? AS INTEGER)) DESC" '[2,-1]'

echo "-- 4. the GROUP BY KEY --"
both "GROUP BY CAST(? AS INTEGER)"        "SELECT COUNT(*) FROM T GROUP BY CAST(? AS INTEGER)" '[2]'
both "the key AND a typed constant item: two slots" \
     "SELECT CAST(? AS INTEGER) K, COUNT(*) FROM T GROUP BY CAST(? AS INTEGER)" '[7,2]'
both "GROUP BY COALESCE(?, 0)"            "SELECT COUNT(*) FROM T GROUP BY COALESCE(?, 0)" '[null]'
both "GROUP BY N + CAST(? AS INTEGER)"    "SELECT COUNT(*) FROM T GROUP BY N + CAST(? AS INTEGER)" '[1]'
both "GROUP BY COALESCE(?, N)"            "SELECT COUNT(*) FROM T GROUP BY COALESCE(?, N)" '[null]'
both "GROUP BY 1 naming COALESCE(?, N)"   "SELECT COALESCE(?, N), COUNT(*) FROM T GROUP BY 1" '[null]'
both "over a derived table"               "SELECT COUNT(*) FROM (SELECT ID, N FROM T) X GROUP BY CAST(? AS INTEGER)" '[2]'
both "NUMBERING: WHERE, GROUP BY, HAVING in text order" \
     "SELECT COUNT(*) FROM T WHERE ID > CAST(? AS SMALLINT) GROUP BY CAST(? AS VARCHAR(5)) HAVING COUNT(*) > CAST(? AS BIGINT)" '[1,"x",1]'

echo "-- 5. CONTROLS: shapes the engine itself refuses --"
both_refuse "SUM(ID * ?) - untyped operand"  "SELECT SUM(ID * ?) FROM T" '[2]'
both_refuse "SUM(?) - bare"                  "SELECT SUM(?) FROM T" '[2]'
both_refuse "ORDER BY ? - bare"              "SELECT ID FROM T ORDER BY ?" '[1]'
both_refuse "ORDER BY ID + ?"                "SELECT ID FROM T ORDER BY ID + ?" '[1]'
both_refuse "GROUP BY ? - bare"              "SELECT COUNT(*) FROM T GROUP BY ?" '[1]'
both_refuse "GROUP BY N + ?"                 "SELECT COUNT(*) FROM T GROUP BY N + ?" '[1]'
both_refuse "a keyed item whose ? is not the key's ? (-104)" \
     "SELECT N + CAST(? AS INTEGER), COUNT(*) FROM T GROUP BY N + CAST(? AS INTEGER)" '[1,1]'

echo "-- 6. CONTROLS: what already worked --"
both "WHERE ID = ?"                       "SELECT ID FROM T WHERE ID = ?" '[2]'
both "HAVING SUM(ID) > ?"                 "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ?" '[3]'
both "HAVING SUM(ID) > COALESCE(?, 0)"    "SELECT N FROM T GROUP BY N HAVING SUM(ID) > COALESCE(?, 0)" '[null]'
both "SUM(ID * 2) - no parameter"         "SELECT SUM(ID * 2) FROM T"
both "ORDER BY ID * -1 - no parameter"    "SELECT ID FROM T ORDER BY ID * -1"
both "GROUP BY N + 1 - no parameter"      "SELECT COUNT(*) FROM T GROUP BY N + 1"
both "a typed ? in a grouped select list" "SELECT CAST(? AS INTEGER), COUNT(*) FROM T GROUP BY N" '[7]'
# the engine types a HAVING `?` from COUNT(*) INCLUDING its NOT NULL -
# this server announced it Nullable until the comparison-typing chunk
# gave the HAVING claim the aggregate's own nullability (agg_param_flags)
both "HAVING COUNT(*) > ? - the input slot's nullability" "SELECT COUNT(*) FROM T HAVING COUNT(*) > ?" '[1]'

echo "-- 7. the comparison-typing law (a ? inside arithmetic under a compare) --"
# the engine types such a `?` from the OTHER side of the comparison
# (measured: `HAVING SUM(ID) > ? + 1` describes INT64, `N + ? > 4` LONG
# NOT NULL from the literal). These refused at PARSE - texpr_atom_bare
# had no Tok::Param arm, so the term never reached resolve_expr_term -
# until the comparison-typing chunk; serve-real-cmpparam carries the law
both "HAVING SUM(ID) > ? + 1"             "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + 1" '[2]'
both "HAVING N + ? > 4"                   "SELECT N FROM T GROUP BY N HAVING N + ? > 4" '[1]'
both "WHERE ID * ? = 2"                   "SELECT ID FROM T WHERE ID * ? = 2" '[2]'
# a `?` in a CASE/IIF CONDITION is typed from the comparison - the same
# law, inside the conditional, through resolve_raw_cond_sink; the ORDER
# BY router reaches it through resolve_expr_sink
both "ORDER BY IIF(ID = CAST(? AS INTEGER), 0, 1)" "SELECT ID FROM T ORDER BY IIF(ID = CAST(? AS INTEGER), 0, 1), ID" '[2]'

echo "-- 8. RECORDED: a grouped query's NON-AGGREGATE order expression (not a parameter matter) --"
eng_only "GROUP BY N ORDER BY COALESCE(?, N) DESC" "SELECT N, COUNT(*) FROM T GROUP BY N ORDER BY COALESCE(?, N) DESC" '[null]'
eng_only "GROUP BY N ORDER BY N + 1 DESC - no parameter, same refusal" "SELECT N, COUNT(*) FROM T GROUP BY N ORDER BY N + 1 DESC"
eng_only "..so the four-clause statement refuses on its ORDER BY" \
     "SELECT COUNT(*) FROM T WHERE ID > CAST(? AS SMALLINT) GROUP BY CAST(? AS VARCHAR(5)) HAVING COUNT(*) > CAST(? AS BIGINT) ORDER BY CAST(? AS DOUBLE PRECISION)" '[1,"x",1,2.5]'
# the grouped DERIVED planner parses its WHERE after its GROUP BY, so a
# `?` in both cannot number in text order: refused rather than swapped
eng_only "derived: a ? in BOTH the WHERE and the GROUP BY key" \
     "SELECT COUNT(*) FROM (SELECT ID, N FROM T) X WHERE X.ID > CAST(? AS SMALLINT) GROUP BY CAST(? AS INTEGER)" '[1,2]'

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN, never typed. It catches what
# a pass/fail tally cannot: cells SILENTLY DISAPPEARING - an early
# `exit`, a helper renamed, a `node` that stopped resolving.
if [ "$ran" -lt 66 ]; then
    echo "FAIL only $ran checks ran; 66 were measured - cells went missing"; fail=1
fi
exit $fail
