#!/bin/bash
# UNARY MINUS OF A SMALLINT / INTEGER MINIMUM RAISES, IT DOES NOT WRAP.
#
# Negation is 0 - x; when x is the minimum of its type the positive
# result overflows the type width, so the engine raises SQLSTATE 22003
# "Integer overflow" - `-CAST(-2147483648 AS INTEGER)` is +2147483648,
# one past INT32_MAX. fire-crab computed +2147483648 but announced the
# result as a 2/4-byte SMALLINT/INTEGER slot, so the client read a
# WRAPPED value back (-32768 / -2147483648) - a confident wrong scalar.
# The BIGINT and INT128 negations already raised; this adds the missing
# check on the narrow (i16/i32) backing, which also covers a NUMERIC(p,0)
# / NUMERIC(p,s) whose backing is that width.
#
# Held against the live engine: a value, or the 22003 refusal.
#
# Usage: qa/serve-real-negoverflow.sh [port]   (default 4156)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4156}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/negoverflow.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/negoverflow-build.log 2>&1 <<'SQL'
create table m (si smallint, ii integer, bi bigint, n40 numeric(4,0), n90 numeric(9,0), n42 numeric(4,2));
commit;
insert into m values (-32768, -2147483648, -9223372036854775808, -3276, -214748364, -32.76);
insert into m values (-32767, -2147483647, -9223372036854775807, -3275, -214748363, -32.75);
commit;
SQL
if grep -qi error /tmp/negoverflow-build.log; then echo "FAIL fixture:"; sed 's/^/  /' /tmp/negoverflow-build.log; exit 1; fi
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-negoverflow.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }
E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "R$(printf '%s' "$r"|grep -o '2200[0-9]'|head -1)"; else printf '%s' "$r" | grep -iE '^V ' | tr '\n' ',' | sed 's/ //g;s/V//g'; fi; }
agree() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
echo "-- minimum negation: 22003 (was a wrapped value) --"
agree "-si (SMALLINT min)"    "select -si v from m where si=-32768;"
agree "-ii (INTEGER min)"     "select -ii v from m where ii=-2147483648;"
agree "-bi (BIGINT min)"      "select -bi v from m where bi=-9223372036854775808;"
agree "-CAST(-32768 SMALLINT)" "select -cast(-32768 as smallint) v from rdb\$database;"
agree "-CAST(-2147483648 INT)" "select -cast(-2147483648 as integer) v from rdb\$database;"
agree "-n40 (NUMERIC(4,0) min)" "select -cast(-3276 as numeric(4,0))*10 v from rdb\$database;"
agree "-CAST(-327.68 NUM(4,2))" "select -cast(-327.68 as numeric(4,2)) v from rdb\$database;"
agree "-CAST(-2147483648 NUM(9,0))" "select -cast(-2147483648 as numeric(9,0)) v from rdb\$database;"
echo "-- controls: non-minimum negation and stored values answer --"
agree "-si non-min"          "select -si v from m where si=-32767;"
agree "-ii non-min"          "select -ii v from m where ii=-2147483647;"
agree "-CAST(-32767 SMALLINT)" "select -cast(-32767 as smallint) v from rdb\$database;"
agree "-100.50"              "select -cast(100.5 as numeric(9,2)) v from rdb\$database;"
agree "-(si*1) widens"       "select -(si*1) v from m where si=-32768;"
agree "-n90 non-min"         "select -n90 v from m order by v;"
agree "stored si"            "select si v from m order by si;"
agree "-CAST(-5 INT)"        "select -cast(-5 as integer) v from rdb\$database;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS negoverflow" || echo "FAIL negoverflow"
exit $fail
