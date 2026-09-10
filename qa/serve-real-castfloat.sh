#!/bin/bash
# CAST(x AS FLOAT) IS SINGLE PRECISION - 482/len4, EIGHT DIGITS - NOT
# DOUBLE, AND REAL IS ITS SYNONYM.
#
# Firebird FLOAT is 4-byte single precision (sqltype 482, len 4) and
# renders at ~8 significant digits; DOUBLE PRECISION is 8-byte (480,
# len 8) at ~16. fire-crab collapsed EVERY approximate cast to DOUBLE:
# CAST(3.14159265358979 AS FLOAT) answered sqltype 480 len 8 with the
# full 3.141592653589790 where the engine answers 482 len 4 with
# 3.1415927 - a wrong type AND a wrong (over-precise) value. CAST AS
# REAL was not even parsed (42000). And MIN/MAX over a FLOAT column
# announced DOUBLE with the widened binary expansion (0.1000000014901161
# for a FLOAT 0.1) instead of the column's own FLOAT.
#
# The stored-FLOAT-column path, render_float (8 digits), SUM/AVG-widen-
# to-DOUBLE, and FLOAT arithmetic (FLOAT+FLOAT -> DOUBLE) were already
# engine-correct and are unchanged. The fix adds a single-precision cast
# target (FLOAT and its REAL synonym) that narrows the value to f32 and
# announces the 4-byte slot, and makes MIN/MAX keep the source column's
# own FLOAT describe. An overflow past f32 range raises 22003 (the
# engine's, not a silent Infinity). Held against the live engine; DOUBLE
# PRECISION is the regression guard.
#
# Usage: qa/serve-real-castfloat.sh [port]   (default 4151)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4151}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/castfloat-eng.fdb"; FC="$D/castfloat-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/castfloat-build.log 2>&1 <<'SQL'
create table t(id int, f float, d double precision);
commit;
insert into t values (1, 3.14159265358979, 3.14159265358979);
insert into t values (2, 0.1, 0.1);
insert into t values (3, -2.5, -2.5);
commit;
SQL
if grep -qi error /tmp/castfloat-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/castfloat-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castfloat.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the full SQLDA line AND the value (or the SQLSTATE) together
sig() { local r; r=$(printf 'set list on;\nset sqlda_display on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -viE '^$|SQL>|Database:'); \
    if printf '%s' "$r" | grep -qiE 'arithmetic exception|overflow|conversion error|SQLSTATE'; then \
        printf '%s' "$r" | grep -oiE '2200[0-9]|arithmetic exception|Dynamic SQL Error' | head -1; \
    else printf '%s' "$r" | grep -iE '^01: sqltype|^X ' | sed 's/  */ /g' | tr '\n' '|'; fi; }
agree() { # <label> <sql>
    local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi
}

echo "-- the bug: CAST AS FLOAT/REAL is single precision (482/len4, 8 digits) --"
agree "CAST pi AS FLOAT"    "select cast(3.14159265358979 as float) x from rdb\$database;"
agree "CAST pi AS REAL"     "select cast(3.14159265358979 as real) x from rdb\$database;"
agree "CAST 0.1 AS FLOAT"   "select cast(0.1 as float) x from rdb\$database;"
agree "CAST 1.0/3 AS FLOAT" "select cast(1.0/3 as float) x from rdb\$database;"
agree "CAST long-dec FLOAT" "select cast(1.23456789012345 as float) x from rdb\$database;"
agree "CAST int AS FLOAT"   "select cast(42 as float) x from rdb\$database;"
agree "CAST text AS FLOAT"  "select cast('2.5' as float) x from rdb\$database;"
agree "CAST neg AS FLOAT"   "select cast(-2.5 as float) x from rdb\$database;"
echo "-- overflow past f32 range raises 22003, not a silent Infinity --"
agree "CAST 1e40 AS FLOAT"  "select cast(1e40 as float) x from rdb\$database;"
agree "CAST 1e300 AS FLOAT" "select cast(1e300 as float) x from rdb\$database;"
echo "-- MIN/MAX of a FLOAT column keep FLOAT; SUM/AVG widen to DOUBLE --"
agree "MIN(f)"              "select min(f) x from t;"
agree "MAX(f)"              "select max(f) x from t;"
agree "SUM(f) -> DOUBLE"    "select sum(f) x from t;"
agree "AVG(f) -> DOUBLE"    "select avg(f) x from t;"
echo "-- FLOAT text form, comparison, ordering --"
agree "CAST(FLOAT AS VARCHAR)" "select cast(cast(3.14159 as float) as varchar(30)) x from rdb\$database;"
agree "WHERE FLOAT cmp"     "select id x from t where f > cast(0.5 as float) order by id;"
agree "float = float count" "select count(*) x from t where f = cast(0.1 as float);"
echo "-- regression: DOUBLE PRECISION and arithmetic widening unchanged --"
agree "CAST AS DOUBLE PREC" "select cast(3.14159265358979 as double precision) x from rdb\$database;"
agree "FLOAT+FLOAT widens"  "select cast(3.14159 as float)+cast(3.14159 as float) x from rdb\$database;"
agree "FLOAT cast + 0"      "select cast(3.14159 as float)+0 x from rdb\$database;"
agree "stored FLOAT col"    "select f x from t where id=1;"
agree "stored DOUBLE col"   "select d x from t where id=1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS castfloat" || echo "FAIL castfloat"
exit $fail
