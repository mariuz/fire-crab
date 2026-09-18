#!/bin/bash
# A COALESCE TYPES ITS PARAMETER ARGUMENT FROM THE RECONCILED TYPE OF ITS
# NON-PARAMETER SIBLINGS. This server took the FIRST sibling, and so
# agreed only when that sibling happened to BE the reconciled type - the
# coincidence that hid it for as long as it stood.
#
# EVERY CELL COMPARES THE VALUE *AND* THE ANNOUNCED INPUT DESCRIPTOR.
# `COALESCE(?, N, BI)` and `COALESCE(?, 0, H)` store the SAME value on
# both servers while describing LONG len 4 here against the engine's
# INT64 len 8 / INT128 len 16 - a value-only probe called them OK. The
# describe is what a client binds against.
#
# AND EVERY CELL WRITES A SENTINEL FIRST. A refused UPDATE leaves the row
# as the PREVIOUS cell left it, which in an earlier probe of mine was the
# very value the engine then wrote - agreement manufactured by cell
# order. With 9.99 in the row beforehand, a refusal cannot look like a
# match.
#
# THE LAW, measured on the engine's own input SQLDA and order-independent:
#   TEXT > DECFLOAT(34 > 16) > DOUBLE > FLOAT > exact; and within the
#   exact family the WIDEST rank, the MOST NEGATIVE scale and the
#   HIGHEST sub_type (0 plain < 1 NUMERIC < 2 DECIMAL), each reconciled
#   INDEPENDENTLY - `COALESCE(?, DE1, NU4)` takes INT64 from the
#   DECIMAL(18,1) and scale -4 from the NUMERIC(9,4), two different
#   siblings, which is precisely what a "first sibling" rule cannot say.
#   A NULL literal is not a sibling at all.
#
# Usage: qa/serve-real-coalescesib.sh [port]   (default 4375)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4375}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/csib-eng.fdb"; FC="$D/csib-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/csib-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NM NUMERIC(9,2), N INTEGER, BI BIGINT, SM SMALLINT,
                H INT128, HS NUMERIC(38,4), D4 NUMERIC(18,4), NU4 NUMERIC(9,4),
                DE4 DECIMAL(9,4), DE1 DECIMAL(18,1), SMS NUMERIC(4,2),
                F16 DECFLOAT(16), F34 DECFLOAT(34), DP DOUBLE PRECISION,
                FL FLOAT, S3 VARCHAR(3), S30 VARCHAR(30), TGT VARCHAR(40));
COMMIT;
INSERT INTO T VALUES (1, 0.00, 3, 9, 2, 11, 1.5000, 0.0000, 0.0000,
                      0.0000, 0.0, 0.00, 1.5, 1.5, 2.5, 1.5, 'ab', 'abc', 'zz');
COMMIT;
SQL
if grep -qi error /tmp/csib-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/csib-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-csib.log 2>&1 &
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
# every cell starts from a SENTINEL, so a refusal cannot read as a match
sentinel() {
    run "$REAL" "$ENG" "UPDATE T SET NM = 9.99, TGT = 'zz' WHERE ID = 1" '[]' >/dev/null
    run "$PORT" "$FC"  "UPDATE T SET NM = 9.99, TGT = 'zz' WHERE ID = 1" '[]' >/dev/null
}
# <label> <value-expr> [col] [json] - value AND describe must both match
both() {
    ran=$((ran + 1))
    local col="${3:-NM}" js="${4:-[1.25]}" st ev fv ed fd
    st="UPDATE T SET $col = $2 WHERE ID = 1"
    sentinel
    run "$REAL" "$ENG" "$st" "$js" >/dev/null; ev=$(run "$REAL" "$ENG" "SELECT $col FROM T WHERE ID=1" '[]')
    run "$PORT" "$FC"  "$st" "$js" >/dev/null; fv=$(run "$PORT" "$FC"  "SELECT $col FROM T WHERE ID=1" '[]')
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$st"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$st")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = "9.99" ] && [ "$fv" = "9.99" ]; then
        echo "FAIL $1 [VACUOUS: neither side wrote - both left the sentinel]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# a RECORDED describe divergence: the value agrees, the announcement does
# not, and this cell SAYS SO when that stops being true
desc_differs() {
    ran=$((ran + 1))
    local col="${3:-NM}" js="${4:-[1.25]}" st ev fv ed fd
    st="UPDATE T SET $col = $2 WHERE ID = 1"
    sentinel
    run "$REAL" "$ENG" "$st" "$js" >/dev/null; ev=$(run "$REAL" "$ENG" "SELECT $col FROM T WHERE ID=1" '[]')
    run "$PORT" "$FC"  "$st" "$js" >/dev/null; fv=$(run "$PORT" "$FC"  "SELECT $col FROM T WHERE ID=1" '[]')
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$st"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$st")
    if [ "$ev" != "$fv" ]; then
        echo "FAIL $1 - the VALUE diverged too, which this cell does not cover"
        echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`both\`"; fail=1
    else echo "OK   $1 (recorded describe gap: eng=[$ed] fc=[$fd])"; fi
}
# the engine ANSWERS and this server deliberately REFUSES
eng_only() {
    ran=$((ran + 1))
    local col="${3:-NM}" js="${4:-[1.25]}" st ev fv
    st="UPDATE T SET $col = $2 WHERE ID = 1"
    sentinel
    run "$REAL" "$ENG" "$st" "$js" >/dev/null; ev=$(run "$REAL" "$ENG" "SELECT $col FROM T WHERE ID=1" '[]')
    run "$PORT" "$FC"  "$st" "$js" >/dev/null; fv=$(run "$PORT" "$FC"  "SELECT $col FROM T WHERE ID=1" '[]')
    if [ "$ev" = "9.99" ]; then
        echo "FAIL $1 - the ENGINE no longer answers this; the boundary moved"; fail=1
    elif [ "$fv" != "9.99" ]; then
        echo "FAIL $1 - THIS SERVER NOW ANSWERS [$fv]; promote this cell"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
# both refuse; the vector may differ
both_refuse() {
    ran=$((ran + 1))
    local col="${3:-NM}" js="${4:-[1.25]}" st ev fv
    st="UPDATE T SET $col = $2 WHERE ID = 1"
    sentinel
    run "$REAL" "$ENG" "$st" "$js" >/dev/null; ev=$(run "$REAL" "$ENG" "SELECT $col FROM T WHERE ID=1" '[]')
    run "$PORT" "$FC"  "$st" "$js" >/dev/null; fv=$(run "$PORT" "$FC"  "SELECT $col FROM T WHERE ID=1" '[]')
    if [ "$ev" != "9.99" ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ "$fv" != "9.99" ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    else echo "OK   both refuse: $1"; fi
}

echo "-- 1. the exact family: rank, scale and sub_type reconciled INDEPENDENTLY --"
both "COALESCE(?, 0, 0.5)"          "COALESCE(?, 0, 0.5)"
both "COALESCE(?, 0, D4)"           "COALESCE(?, 0, D4)"
both "COALESCE(?, 0, 0.5, D4)"      "COALESCE(?, 0, 0.5, D4)"
both "COALESCE(?, N, BI)  [describe-only]"  "COALESCE(?, N, BI)"
both "COALESCE(?, 0, H)   [describe-only]"  "COALESCE(?, 0, H)"
both "COALESCE(?, N, H)   [describe-only]"  "COALESCE(?, N, H)"
both "COALESCE(?, 0, HS)"           "COALESCE(?, 0, HS)"
both "COALESCE(?, NU4, DE4) sub_type 2"     "COALESCE(?, NU4, DE4)"
both "COALESCE(?, 0, DE4)"          "COALESCE(?, 0, DE4)"
both "COALESCE(?, DE1, NU4) two siblings"   "COALESCE(?, DE1, NU4)"
both "COALESCE(?, SM, 0) widens to LONG"    "COALESCE(?, SM, 0)"
both "COALESCE(?, SM, SMS)"         "COALESCE(?, SM, SMS)"
both "COALESCE(?, 0.5, NU4)"        "COALESCE(?, 0.5, NU4)"

echo "-- 2. the family precedence: DECFLOAT > DOUBLE > FLOAT > exact --"
both "COALESCE(?, 0, DP)"           "COALESCE(?, 0, DP)"
both "COALESCE(?, 0, FL)"           "COALESCE(?, 0, FL)"
both "COALESCE(?, FL, DP) DOUBLE wins"      "COALESCE(?, FL, DP)"
# (the DECFLOAT siblings are section 7: they refuse, and refused BEFORE
#  this chunk too - measured against the previous binary with a sentinel)

echo "-- 3. a NULL literal is NOT a sibling --"
both "COALESCE(?, NULL, 0.5) types from the 0.5" "COALESCE(?, NULL, 0.5)"
both_refuse "COALESCE(?, NULL) - the engine's -804" "COALESCE(?, NULL)"

echo "-- 4. CONTROLS: the first sibling ALREADY was the reconciled type --"
# these agreed BEFORE the fix and must still agree: they are what shows
# the change did not simply repaint every cell
both "COALESCE(?, 0)"               "COALESCE(?, 0)"
both "COALESCE(?, 0.5)"             "COALESCE(?, 0.5)"
both "COALESCE(?, D4, 0)"           "COALESCE(?, D4, 0)"
both "COALESCE(?, DP, 0)"           "COALESCE(?, DP, 0)"
both "COALESCE(?, DE4, NU4)"        "COALESCE(?, DE4, NU4)"
both "COALESCE(?, HS, H)"           "COALESCE(?, HS, H)"
both "COALESCE(?, SM)"              "COALESCE(?, SM)"
both "COALESCE(?, SMS)"             "COALESCE(?, SMS)"

echo "-- 5. CONTROLS: all-text reconciles, into a TEXT destination --"
both "TGT = COALESCE(?, S3, S30)"   "COALESCE(?, S3, S30)" TGT '["q"]'
both "TGT = COALESCE(?, S3)"        "COALESCE(?, S3)"      TGT '["q"]'
both "TGT = COALESCE(?, 'lit')"     "COALESCE(?, 'lit')"   TGT '["q"]'

echo "-- 6. CONTROLS: shapes the ENGINE refuses must keep refusing --"
# COALESCE pushes no type into its arguments, so a MULTIPLY or DIVIDE
# over the untyped parameter is an error there, not a value
both_refuse "COALESCE(? * 2, 0.5)"  "COALESCE(? * 2, 0.5)"
both_refuse "COALESCE(? / 2, 0.5)"  "COALESCE(? / 2, 0.5)"

echo "-- 7. RECORDED, NOT FIXED --"
# (a) TEXT beside a NUMBER: the engine reconciles to VARYING whose width
#     is the NUMBER'S RENDERED width (11 beside INTEGER, 23 beside
#     DECFLOAT(16), 24 beside DOUBLE - measured). Reproducing that needs
#     the value side to render exactly as the engine does, which is the
#     same boundary the UNION reconciliation draws. A refusal replacing
#     a wrong value, held here so it cannot drift unnoticed.
eng_only "COALESCE(?, 0, S3)  text beside a number"   "COALESCE(?, 0, S3)"
eng_only "COALESCE(?, S3, F16) text beside decfloat"  "COALESCE(?, S3, F16)"
eng_only "COALESCE(?, S3, DP)  text beside double"    "COALESCE(?, S3, DP)"
# (b) PRE-EXISTING and unrelated to COALESCE, proven pre-existing by
#     running this gate's own probe against the previous binary: NULLIF,
#     CASE and IIF push the DESTINATION's scale down but the engine
#     announces a WIDENED RANK - INT64 len 8 for a NUMERIC(9,2)
#     destination, where this server announces LONG len 4. The VALUE
#     agrees; only the announcement differs.
# (c) A DECFLOAT SIBLING. These refuse here and answer on the engine -
#     and they REFUSED BEFORE THIS CHUNK TOO, measured against
#     /tmp/fcwire-prev-da9e3cf with a sentinel, so they are neither a fix
#     nor a regression. The cause is deliberate and documented: a
#     `CastTarget::DecFloat` cast has no `ExprType` ([Expr::type_of]
#     returns None for it, to "fail-close any attempt to nest it where a
#     type is needed - a conditional branch"), and a COALESCE branch is
#     exactly such a place. Giving DECFLOAT an ExprType is its own
#     capability, not this one. [coalesce_sibling_desc] reconciles them
#     correctly; the refusal is downstream of it.
eng_only "COALESCE(?, 0, F16)   decfloat sibling"   "COALESCE(?, 0, F16)"
eng_only "COALESCE(?, 0, F34)   decfloat sibling"   "COALESCE(?, 0, F34)"
eng_only "COALESCE(?, F16, F34) 34 would win"       "COALESCE(?, F16, F34)"
eng_only "COALESCE(?, 0.5, F16)"                    "COALESCE(?, 0.5, F16)"
eng_only "COALESCE(?, DP, F16)  over a double"      "COALESCE(?, DP, F16)"
desc_differs "NULLIF(?, 0.5)"       "NULLIF(?, 0.5)"
desc_differs "CASE ... THEN ? ELSE 0.5 END" "CASE WHEN ID=1 THEN ? ELSE 0.5 END"
desc_differs "IIF(ID=1, ?, 0.5)"    "IIF(ID=1, ?, 0.5)"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN (42 on the fixing binary),
# never typed. It catches what a pass/fail tally cannot: cells SILENTLY
# DISAPPEARING - an early `exit`, a helper renamed, a `node` that stopped
# resolving - which otherwise reports a clean sweep over nothing.
if [ "$ran" -lt 42 ]; then
    echo "FAIL only $ran checks ran; 42 were measured - cells went missing"; fail=1
fi
exit $fail
