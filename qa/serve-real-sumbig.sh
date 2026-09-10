#!/bin/bash
# SUM OVER A BIGINT WIDENS TO INT128 - NO SILENT 64-BIT WRAP.
#
# The engine promotes an integer SUM one storage bucket up: SMALLINT and
# INTEGER -> BIGINT (INT64), and BIGINT -> INT128. It announces the
# result INT128 (sqltype 32752, len 16) for EVERY BIGINT sum, even one
# that would fit in 64 bits, and it accumulates in 128 bits so a total
# past 2^63 is carried, not wrapped.
#
# fire-crab's lone-aggregate fast path (a single SUM with no GROUP BY,
# computed on an integer column) folded in an i64 accumulator and
# hardcoded an INT64/len-8 describe. So SUM over two 9e18 BIGINTs came
# back as sqltype 580 INT64 with the value -446744073709551616 - the
# true 18000000000000000000 wrapped mod 2^64, negative, with no error
# raised. A confident wrong number: the project law's worst case.
#
# The fix declines SUM-over-INT64 in that fast path so it falls through
# to the group machinery, which accumulates in i128 and describes
# INT128 - exactly the route a scaled-numeric SUM already took. MIN/MAX
# over the same BIGINT do NOT widen (INT64) and stay on the fast path;
# SUM over SMALLINT/INTEGER stays INT64; AVG is unchanged. Held against
# the live engine for value AND announced SQLDA type/length.
#
# Usage: qa/serve-real-sumbig.sh [port]   (default 4148)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4148}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/sumbig-gate-eng.fdb"; FC="$D/sumbig-gate-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/sumbig-build.log 2>&1 <<'SQL'
create table t(id integer, b bigint, s smallint, i integer, n numeric(18,2), h int128);
create index tb on t(b);
commit;
insert into t values (1,  9000000000000000000, 100, 2000000000, 90000000000000.55,  9000000000000000000);
insert into t values (2,  9000000000000000000, 200, 2000000000, 90000000000000.55,  9000000000000000000);
insert into t values (3, -5000000000000000000, -50, 1000000000,  1000000000000.11, -5000000000000000000);
commit;
SQL
if grep -qi error /tmp/sumbig-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/sumbig-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-sumbig.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the described sqltype/len line(s) AND every value row, together
sig() { printf 'set list on;\nset sqlda_display on;\n%s\n' "$2" \
    | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -iE '^01: sqltype|^02: sqltype|^X ' | sed 's/  */ /g'; }
agree() { # <label> <sql>
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi
}

echo "-- the bug: SUM(BIGINT) is INT128, and the value does not wrap --"
agree "SUM(b) overflow"        "select sum(b) x from t;"
agree "SUM(b) single (8e18)"   "select sum(b) x from t where id=1;"
agree "SUM(b) negative dir"    "select sum(b) x from t where b<0 or id<=2;"
agree "SUM(b) indexed scan"    "select sum(b) x from t where b<0;"
agree "SUM(b) all filtered"    "select sum(b) x from t where b>9e18;"
agree "SUM(b) scalar subquery" "select (select sum(b) from t) x from rdb\$database;"
agree "SUM(b)+1 expr"          "select sum(b)+1 x from t;"
agree "SUM(b) grouped"         "select id, sum(b) x from t group by id order by id;"
agree "SUM(b) HAVING"          "select id, sum(b) x from t group by id having sum(b)<0 order by id;"
echo "-- the widening rule holds for the other integer/numeric backings --"
agree "SUM(int128)"            "select sum(h) x from t;"
agree "SUM(numeric(18,2))"     "select sum(n) x from t;"
echo "-- controls: no over-widening --"
agree "SUM(smallint) INT64"    "select sum(s) x from t;"
agree "SUM(integer) INT64"     "select sum(i) x from t;"
agree "MAX(b) stays INT64"     "select max(b) x from t;"
agree "MIN(b) stays INT64"     "select min(b) x from t;"
agree "AVG(b) stays INT64"     "select avg(b) x from t;"
agree "COUNT(b) INT64"         "select count(b) x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS sumbig" || echo "FAIL sumbig"
exit $fail
