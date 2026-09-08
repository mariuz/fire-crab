#!/bin/bash
# A COMPUTED COLUMN TAKES ITS DECLARED FIELD TYPE, not the defining
# expression's natural type.
#
# The engine wraps a computed expression in a CAST to the column's
# RDB$RELATION_FIELDS descriptor (blr_cast to the field format), so the
# stored/returned value is ROUNDED to the column's scale, RANGE-CHECKED
# against its width, and DESCRIBED by its own wire type. fire-crab used
# to type and evaluate the raw expression, so an
#   INTEGER COMPUTED BY (ID / 3.0)
# answered 6.6 as an INT64 scale -1 (should be 7, LONG scale 0), a
#   SMALLINT COMPUTED BY (ID * 1000)
# returned 100000 with NO error (should raise 22003 overflow), and a
#   DOUBLE PRECISION COMPUTED BY (ID / 3.0)
# described as INT64 - corrupting a prepared client's binding.
#
# The fix injects the cast when a computed field is projected and
# describes it by the declared descriptor; the scaled->double conversion
# also now divides (CVT_get_double), matching the engine to the last
# bit. Held against the live engine: value AND SQLDA (sqltype + scale).
#
# Usage: qa/serve-real-computedtype.sh [port]   (default 4146)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4146}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/computedtype.fdb"
rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/computedtype-build.log 2>&1 <<'SQL'
create table t (id integer,
  c_int  integer          computed by (id / 3.0),
  c_si   smallint         computed by (id * 1000),
  c_bi   bigint           computed by (id * 100000000000),
  d1     double precision computed by (id / 3.0),
  c_num  numeric(9,2)     computed by (id / 3.0),
  c_neg  integer          computed by (-id / 2.0),
  c_add  integer          computed by (id + 1));
commit;
insert into t (id) values (20);
insert into t (id) values (7);
commit;
create table ov (id integer, c_si smallint computed by (id * 1000));
commit;
insert into ov (id) values (100);
commit;
SQL
if grep -qi error /tmp/computedtype-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/computedtype-build.log; exit 1; fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-computedtype.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
val() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "REFUSE $(printf '%s' "$r"|grep -oi 'SQLSTATE = [0-9]*'|head -1)"; else printf '%s' "$r" | tr '\n' '|'; fi; }
dsc() { printf 'set sqlda_display on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -i 'sqltype:' | head -1 | grep -o 'sqltype: [0-9]* [A-Za-z]* .*scale: [0-9-]*'; }
agree() { # <label> <sql>
    local ve vf de df
    ve=$(val "127.0.0.1/3050:$DB" "$2"); vf=$(val "127.0.0.1/$PORT:$DB" "$2")
    de=$(dsc "127.0.0.1/3050:$DB" "$2"); df=$(dsc "127.0.0.1/$PORT:$DB" "$2")
    if [ "$ve" = "$vf" ] && [ "$de" = "$df" ]; then echo "OK   $1 v[$ve] {$de}";
    else echo "FAIL $1"; echo "     eng v[$ve] {$de}"; echo "     fc  v[$vf] {$df}"; fail=1; fi
}
agree "INTEGER (20/3.0 -> 7)"        "select c_int from t where id=20;"
agree "INTEGER (7/3.0 -> 2)"         "select c_int from t where id=7;"
agree "SMALLINT (20000, fits)"       "select c_si from t where id=20;"
agree "BIGINT"                       "select c_bi from t where id=20;"
agree "DOUBLE (20/3.0)"              "select d1 from t where id=20;"
agree "NUMERIC(9,2) (6.60)"          "select c_num from t where id=20;"
agree "INTEGER negative (-20/2)"     "select c_neg from t where id=20;"
agree "INTEGER passthrough (id+1)"   "select c_add from t where id=20;"
agree "SMALLINT overflow raises"     "select c_si from ov where id=100;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS computedtype" || echo "FAIL computedtype"
exit $fail
