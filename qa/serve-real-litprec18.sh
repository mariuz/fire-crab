#!/bin/bash
# A NUMERIC LITERAL HAS ARITHMETIC PRECISION 18, SO literal * / any
# operand PROMOTES THE EXACT-NUMERIC RESULT TO INT128 - matching the
# engine's announced type/len (was under-declared INT64).
#
# In dialect 3 every numeric literal (one with a decimal point or an
# exponent) is treated as precision 18 for arithmetic result typing, not
# its digit count. A multiply/divide result backs on INT128 (sqltype
# 32752, len 16) when the operand precisions sum past 18, so a literal in
# any product/quotient promotes (1.5*1.5 = 18+18; n41*1.5 = 4+18=22; both
# INT128). fire-crab ranked a literal by its significand's digit count,
# so a small literal (1.5 = 2 digits) wrongly kept INT64 (len 8) - a
# client reading the describe saw an 8-byte slot where the engine
# promises 16. The VALUE was already correct; this fixes the announced
# sqltype/len (scale and subtype were already right, and the value
# widens into the 16-byte slot unchanged).
#
# Add/subtract does NOT promote on a precision sum (its result backs on
# the wider operand), so 1.5+1.5 stays INT64 - the fix must not leak
# there, and does not (the add/sub rank test is INT128-only). Held
# against the live engine, both directions.
#
# RECORDED, not here: a column/column DIVIDE announces NUMERIC subtype 1
# where the engine says 0 (pre-existing, no literal involved, cosmetic
# descriptor tag); MOD/ABS narrow-int width.
#
# Usage: qa/serve-real-litprec18.sh [port]   (default 4157)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4157}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/litprec18-eng.fdb"; FC="$D/litprec18-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/litprec18-build.log 2>&1 <<'SQL'
create table t(n92 numeric(9,2), n184 numeric(18,4), n41 numeric(4,1), i integer, b bigint);
commit;
insert into t values (12.30, 1.0000, 12.3, 5, 100);
commit;
SQL
if grep -qi error /tmp/litprec18-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/litprec18-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-litprec18.log 2>&1 &
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

echo "-- literal * / any operand promotes to INT128 (was INT64) --"
agree "1.5*1.5"        "select 1.5*1.5 x from t;"
agree "0.1*0.1"        "select 0.1*0.1 x from t;"
agree "12345.678^2"    "select 12345.678*12345.678 x from t;"
agree "1.00/3.00"      "select 1.00/3.00 x from t;"
agree "1.0/8"          "select 1.0/8 x from t;"
agree "0.1/0.3"        "select 0.1/0.3 x from t;"
agree "1.5*1 (lit*int)" "select 1.5*1 x from t;"
agree "n41*1.5 (4+18)" "select n41*1.5 x from t;"
agree "n92*1.5"        "select n92*1.5 x from t;"
agree "b*1.5"          "select b*1.5 x from t;"
agree "1.5*n184"       "select 1.5*n184 x from t;"
echo "-- regressions: add/subtract, bare literals, integer & column arithmetic unchanged --"
agree "1.5+1.5 (INT64)" "select 1.5+1.5 x from t;"
agree "1.5-0.3 (INT64)" "select 1.5-0.3 x from t;"
agree "n184+1.5 (INT64)" "select n184+1.5 x from t;"
agree "bare 1.5"        "select 1.5 x from t;"
agree "bare 12345.678"  "select 12345.678 x from t;"
agree "i*i (INT64)"     "select i*i x from t;"
agree "n92*n92 (18->INT64)" "select n92*n92 x from t;"
agree "n184*n184 (INT128)" "select n184*n184 x from t;"
agree "10/3 integer"    "select 10/3 x from t;"
agree "large lit prod (INT128)" "select 1234567890.12*9876543210.98 x from t;"
agree "i+n92"           "select i+n92 x from t;"
agree "n184/n92 (INT128)" "select n184/n92 x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS litprec18" || echo "FAIL litprec18"
exit $fail
