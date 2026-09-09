#!/bin/bash
# A CONDITIONAL WITH A DECFLOAT BRANCH IS NOT SILENTLY MIS-TYPED.
#
# COALESCE / CASE / IIF / DECODE and NULLIF type their result from the
# branches. fire-crab has no ExprType for DECFLOAT, so a DECFLOAT branch
# was DROPPED from the type fold and the conditional took the SIBLING's
# type - rendering the decfloat value as a confident WRONG number:
#   COALESCE(<decfloat>, <int>)  -> 0   (engine: the decfloat value)
#   COALESCE(<int>, <decfloat>)  -> the int, but a NULL int would have
#                                   truncated the decfloat
#   NULLIF(<decfloat>, <int>)    -> 0   (engine: the decfloat value)
# The engine types such a mix DECFLOAT and coerces the other branch into
# it; a full DECFLOAT result type is a later chunk. Until then fire-crab
# REFUSES the mix (42000) rather than answer a wrong value - the
# project's match-or-refuse law. Non-decfloat conditionals, and NULLIF
# with a non-decfloat first operand, are unchanged.
#
# This asserts fire-crab REFUSES the decfloat mixes (where the engine
# answers) and still MATCHES the engine on the non-decfloat controls.
#
# Usage: qa/serve-real-dfcond.sh [port]   (default 4150)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4150}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/dfcond.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/dfcond-build.log 2>&1 <<'SQL'
create table t (id int, d16 decfloat(16), d34 decfloat(34), n numeric(18,4), i integer);
commit;
insert into t values (1, 2.5, 2.5, 2.5, 2);
insert into t values (2, 10, 10, 10.0, 10);
commit;
SQL
if grep -qi error /tmp/dfcond-build.log; then echo "FAIL fixture:"; sed 's/^/  /' /tmp/dfcond-build.log; exit 1; fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfcond.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "REFUSE"; else printf '%s' "$r" | grep -iE '^(V|ID) ' | tr -d ' \n'; fi; }
fc_refuses() { local f; f=$(sig "$F" "$2"); \
    [ "$f" = "REFUSE" ] && echo "OK   refuse $1  (engine answers a DECFLOAT; fc refuses, not a wrong value)" \
    || { echo "FAIL refuse $1  expected fc REFUSE, got [$f]"; fail=1; }; }
agree() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1  [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }

echo "-- decfloat conditional mixes: fc REFUSES (was a silent-wrong value) --"
fc_refuses "COALESCE(d34, i)"   "select coalesce(d34,i) v from t where id=1;"
fc_refuses "COALESCE(i, d34)"   "select coalesce(i,d34) v from t where id=1;"
fc_refuses "COALESCE(d34, n)"   "select coalesce(d34,n) v from t where id=1;"
fc_refuses "CASE .. d34 .. int" "select case when id=1 then d34 else 5 end v from t where id=1;"
fc_refuses "IIF(.., d34, int)"  "select iif(id=1,d34,5) v from t where id=1;"
fc_refuses "DECODE d34/int"     "select decode(id,1,d34,9) v from t where id=1;"
fc_refuses "NULLIF(d34, i)"     "select nullif(d34,i) v from t where id=1;"
echo "-- controls: non-decfloat conditionals + NULLIF unchanged (must MATCH) --"
agree "COALESCE(i, n)"          "select coalesce(i,n) v from t where id=2;"
agree "COALESCE(null, text)"    "select coalesce(cast(null as varchar(3)),'xx') v from rdb\$database;"
agree "CASE int"                "select case when id=1 then 7 else 9 end v from t where id=1;"
agree "COALESCE(null-num, dbl)" "select coalesce(cast(null as numeric(9,2)),cast(2.5 as double precision)) v from rdb\$database;"
agree "NULLIF(i, d34) -> int"   "select nullif(i,d34) v from t where id=1;"
agree "NULLIF(i, 5)"            "select nullif(i,5) v from t where id=1;"
agree "NULLIF(n, i)"            "select nullif(n,i) v from t where id=2;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS dfcond" || echo "FAIL dfcond"
exit $fail
