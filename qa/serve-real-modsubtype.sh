#!/bin/bash
# MOD OVER A NUMERIC/DECIMAL KEEPS THE OPERAND'S FAMILY CODE (SUBTYPE),
# WHILE ABS DROPS IT - MATCHING THE ENGINE.
#
# MOD copies its dividend's descriptor (makeMod), so MOD over a NUMERIC
# stays subtype 1 and over a DECIMAL subtype 2 - the width and scale
# already matched (LONG/SHORT/INT64, scale 0), only the announced
# sub_type was dropped to 0. fire-crab derived a MOD result's sub_type
# from numeric_subtype, which had a ROUND/TRUNC arm but no MOD arm, so a
# MOD fell to the plain-integer default 0. Adding the MOD arm carries the
# dividend's family code; ABS stays on the default 0 (makeAbs remakes a
# plain integer, dropping the code - probed), and MOD over a plain
# integer stays 0. The value and width are unchanged. Held against the
# live engine for the announced sub_type.
#
# Usage: qa/serve-real-modsubtype.sh [port]   (default 4160)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4160}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/modsubtype-eng.fdb"; FC="$D/modsubtype-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/modsubtype-build.log 2>&1 <<'SQL'
create table t(si smallint, ii integer, bi bigint,
               n92 numeric(9,2), n41 numeric(4,1), n184 numeric(18,4), n38 numeric(38,2),
               d92 decimal(9,2), d18 decimal(18,4));
commit;
insert into t values (10,100,1000, 12.34, 1.5, 9.9999, 12.34, 7.77, 3.3333);
commit;
SQL
if grep -qi error /tmp/modsubtype-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/modsubtype-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-modsubtype.log 2>&1 &
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

echo "-- the fix: MOD over NUMERIC keeps subtype 1, over DECIMAL subtype 2 --"
agree "mod(n92,3) NUMERIC->sub1"  "select mod(n92,3) x from t;"
agree "mod(n41,2) NUMERIC->sub1"  "select mod(n41,2) x from t;"
agree "mod(n184,3) NUMERIC->sub1" "select mod(n184,3) x from t;"
agree "mod(n38,3) NUMERIC->sub1"  "select mod(n38,3) x from t;"
agree "mod(d92,3) DECIMAL->sub2"  "select mod(d92,3) x from t;"
agree "mod(d18,4) DECIMAL->sub2"  "select mod(d18,4) x from t;"
echo "-- MOD over a plain integer keeps subtype 0 --"
agree "mod(si,3)"  "select mod(si,3) x from t;"
agree "mod(ii,3)"  "select mod(ii,3) x from t;"
agree "mod(bi,7)"  "select mod(bi,7) x from t;"
echo "-- ABS drops the family code (stays 0); ROUND/TRUNC keep it; controls --"
agree "abs(n92) sub0"    "select abs(n92) x from t;"
agree "abs(si)"          "select abs(si) x from t;"
agree "round(n92,1)"     "select round(n92,1) x from t;"
agree "trunc(n92,1)"     "select trunc(n92,1) x from t;"
agree "sign(n92)"        "select sign(n92) x from t;"
agree "n92 col (plain)"  "select n92 x from t;"
agree "mod value stays"  "select mod(n92,3) v from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS modsubtype" || echo "FAIL modsubtype"
exit $fail
