#!/bin/bash
# CAST OUT OF DECFLOAT - to VARCHAR, the integer family, NUMERIC/DECIMAL,
# and DOUBLE/FLOAT - matches the engine, where fire-crab used to refuse.
#
# A DECFLOAT operand has no ExprType of its own, so every CAST(<decfloat>
# AS <exact|text|approx>) refused at prepare (SQLSTATE 42000). The cast
# target already drives the describe once type_of stops requiring the
# operand to be typeable; the eval now reads the operand as a decoded
# decimal and:
#   * -> VARCHAR: the canonical decimal string (via the value's render);
#   * -> SMALLINT/INTEGER/BIGINT: rounded HALF AWAY FROM ZERO (2.5 -> 3),
#     with the engine's two overflow classes - a value past the i32
#     intermediate (SMALLINT/INTEGER) or the i64 one (BIGINT) is 22000
#     "decimal float invalid operation", where a value that fits the
#     intermediate but not the SMALLINT target narrows with a 22003;
#   * -> NUMERIC(p,s)/DECIMAL: rounded HALF-UP to the scale, overflow of
#     the backing is 22000;
#   * -> DOUBLE/FLOAT: decimal -> binary through the canonical string,
#     correctly rounded (0.1, 1/3).
# The value was reachable all along; this lands the whole outbound-cast
# family. Held against the live engine.
#
# Usage: qa/serve-real-castfromdecfloat.sh [port]   (default 4161)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4161}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/castfromdf-eng.fdb"; FC="$D/castfromdf-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/castfromdf-build.log 2>&1 <<'SQL'
create table t(df16 decfloat(16), df34 decfloat(34));
commit;
insert into t values (2.5, 3.14159265358979);
commit;
SQL
if grep -qi error /tmp/castfromdf-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/castfromdf-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castfromdf.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# describe + value, or the SQLSTATE (22000/22003/22018) - error text elided
sig() { local r; r=$(printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -viE '^$|SQL>|Database:'); \
    if printf '%s' "$r" | grep -qiE 'SQLSTATE'; then printf '%s' "$r" | grep -oiE 'SQLSTATE = [0-9A-Z]+' | head -1; \
    else printf '%s' "$r" | grep -iE '^01: sqltype|^X ' | sed 's/  */ /g' | tr '\n' '|'; fi; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
df() { printf "cast('%s' as decfloat(34))" "$1"; }

echo "-- to VARCHAR (canonical string) --"
agree "df16 -> varchar" "select cast(df16 as varchar(40)) x from t;"
agree "df34 -> varchar" "select cast(df34 as varchar(40)) x from t;"
echo "-- to the integer family (HALF AWAY FROM ZERO) --"
agree "df16(2.5) -> integer =3" "select cast(df16 as integer) x from t;"
agree "df34(3.14) -> integer =3" "select cast(df34 as integer) x from t;"
agree "df16 -> bigint" "select cast(df16 as bigint) x from t;"
agree "df34 -> smallint" "select cast(df34 as smallint) x from t;"
echo "-- integer overflow classes: i64/i32 intermediate 22000, SMALLINT narrow 22003 --"
agree "1e19 -> bigint (22000)"    "select cast($(df 1e19) as bigint) x from t;"
agree "9e18 -> bigint (fits)"     "select cast($(df 9e18) as bigint) x from t;"
agree "3e9 -> integer (22000)"    "select cast($(df 3e9) as integer) x from t;"
agree "40000 -> smallint (22003)" "select cast($(df 40000) as smallint) x from t;"
echo "-- to NUMERIC/DECIMAL (HALF-UP), backing overflow 22000 --"
agree "df34 -> numeric(18,4)" "select cast(df34 as numeric(18,4)) x from t;"
agree "df16 -> numeric(9,2)"  "select cast(df16 as numeric(9,2)) x from t;"
agree "df34 -> decimal(38,10)" "select cast(df34 as decimal(38,10)) x from t;"
agree "1e18 -> numeric(9,0) (22000)"  "select cast($(df 1e18) as numeric(9,0)) x from t;"
agree "1e30 -> numeric(18,0) (22000)" "select cast($(df 1e30) as numeric(18,0)) x from t;"
agree "1e20 -> numeric(38,0) (fits)"  "select cast($(df 1e20) as numeric(38,0)) x from t;"
agree "1e30 -> numeric(9,2) (22000)"  "select cast($(df 1e30) as numeric(9,2)) x from t;"
echo "-- to DOUBLE / FLOAT (decimal -> binary, correctly rounded) --"
agree "df16 -> double" "select cast(df16 as double precision) x from t;"
agree "0.1 -> double"  "select cast($(df 0.1) as double precision) x from t;"
agree "1/3 -> double"  "select cast(cast('0.3333333333333333' as decfloat(16)) as double precision) x from t;"
agree "df16 -> float"  "select cast(df16 as float) x from t;"
echo "-- non-numeric decfloat text --"
agree "df34 in arithmetic still" "select cast(df34+1 as varchar(40)) x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS castfromdecfloat" || echo "FAIL castfromdecfloat"
exit $fail
