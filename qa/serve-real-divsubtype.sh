#!/bin/bash
# DIVIDE over a NUMERIC/DECIMAL announces the engine's family code
# (sub_type): 0 at the INT64 (BIGINT) result width, the MAX of the
# operands' codes at INT128 - where fire-crab kept the operand's code at
# both widths.
#
# makeDivide's 8-byte path drops the NUMERIC/DECIMAL sub_type to 0, so
# n92/n41 (INT64) is sub_type 0 though both operands are NUMERIC (1); at
# INT128 the divide keeps the code like +/-/* do, so n38/n41 is 1 and
# n92*n41/2 is 1 (the mul made it 1, the divide is INT128), while
# n92/n41/2 is 0 (the inner INT64 divide already reset it). numeric_subtype
# had a single Bin arm taking MAX at every op and width; it now special-
# cases Div by its own result width (rank_of). Width, scale and value are
# unchanged - describe-only. Held against the live engine.
#
# Usage: qa/serve-real-divsubtype.sh [port]   (default 4166)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4166}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/divsub-eng.fdb"; FC="$D/divsub-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/divsub-build.log 2>&1 <<'SQL'
create table t(n92 numeric(9,2), n41 numeric(4,1), n184 numeric(18,4), n38 numeric(38,2),
               d92 decimal(9,2), d18 decimal(18,4), ii integer, bi bigint, si smallint);
commit;
insert into t values (12.34, 1.5, 9.9999, 12.34, 7.77, 3.3333, 100, 1000, 10);
commit;
SQL
if grep -qi error /tmp/divsub-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/divsub-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-divsub.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^X ' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }

echo "-- the fix: DIVIDE at INT64 width resets sub_type to 0 --"
agree "n92/n41 INT64 sub0" "select n92/n41 x from t;"
agree "n92/2 INT64 sub0"   "select n92/2 x from t;"
agree "n92/ii INT64 sub0"  "select n92/ii x from t;"
agree "d92/n41 INT64 sub0" "select d92/n41 x from t;"
echo "-- DIVIDE at INT128 width keeps MAX of operand codes --"
agree "n38/n41 INT128 sub1"  "select n38/n41 x from t;"
agree "n184/n41 INT128 sub1" "select n184/n41 x from t;"
agree "n184/n92 INT128 sub1" "select n184/n92 x from t;"
agree "n38/2 INT128 sub1"    "select n38/2 x from t;"
agree "d18/n41 INT128 sub2"  "select d18/n41 x from t;"
echo "-- nested: an inner divide that reset stays 0 through outer INT128 --"
agree "n92/n41/2 sub0"  "select n92/n41/2 x from t;"
agree "n92/n41*2 sub0"  "select n92/n41*2 x from t;"
agree "n92*n41/2 sub1 (mul then div)" "select n92*n41/2 x from t;"
echo "-- controls: +/-/* keep MAX at every width; integer divide stays 0 --"
agree "n92*n41 sub1"   "select n92*n41 x from t;"
agree "n92+n41 sub1"   "select n92+n41 x from t;"
agree "n92-n41 sub1"   "select n92-n41 x from t;"
agree "bi/ii INT128 sub0" "select bi/ii x from t;"
agree "ii/si sub0"     "select ii/si x from t;"
agree "round(n92,1) sub1" "select round(n92,1) x from t;"
agree "n92 col sub1"   "select n92 x from t;"
agree "divide VALUE unchanged" "select n92/n41 v from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS divsubtype" || echo "FAIL divsubtype"
exit $fail
