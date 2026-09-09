#!/bin/bash
# A MERGE READS THE STATEMENT-START SNAPSHOT, NOT ITS OWN WRITES.
#
# A MERGE is one request over one image: every subquery that reads the
# target - in a WHEN MATCHED ... UPDATE SET, a WHEN MATCHED ... AND
# <cond>, or a WHEN NOT MATCHED ... INSERT VALUES(...) - evaluates
# against the target as it stood at statement start, exactly like a
# plain searched UPDATE. fire-crab desugared each matched row into a
# per-row UPDATE against the LIVE, growing image, so
#   WHEN MATCHED THEN UPDATE SET n = (SELECT SUM(n) FROM t)
# grew 60,110,200 (each row reading rows written before it - a Halloween
# problem) where the engine writes 60,60,60. The fix folds every branch
# subquery under the MERGE's start image (SubqImageGuard) while the
# write still lands on the live image, so earlier rows' writes
# accumulate and uniqueness is still enforced.
#
# Each probe runs the SAME statement over an engine db and a
# byte-identical fire-crab copy taken BEFORE the statement, then
# compares the final table. Plain UPDATE is the control (already right).
#
# Usage: qa/serve-real-mergesnap.sh [port]   (default 4151)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4151}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; TPL="$D/mergesnap-tpl.fdb"; ENG="$D/mergesnap-eng.fdb"; FC="$D/mergesnap-fc.fdb"
rm -f "$TPL"
echo "create database '127.0.0.1/3050:$TPL' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $TPL"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$TPL" >/tmp/mergesnap-build.log 2>&1 <<'SQL'
create table t (id integer primary key, n integer);
commit;
SQL
if grep -qi error /tmp/mergesnap-build.log; then echo "FAIL fixture:"; sed 's/^/  /' /tmp/mergesnap-build.log; exit 1; fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-mergesnap.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

fail=0
seed() { # reset the template's rows to the seed, then copy to eng+fc
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$TPL" >/dev/null 2>&1 <<'SQL'
delete from t;
insert into t values (1,10); insert into t values (2,20); insert into t values (3,30);
commit;
SQL
    cp "$TPL" "$ENG"; cp "$TPL" "$FC"; chmod 666 "$ENG" "$FC"
}
final() { printf 'set list on;\nselect id||%s||coalesce(cast(n as varchar(20)),%s) r from t order by id;\n' "'='" "'null'" \
    | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^R ' | sed 's/^R//' | tr -d ' \n'; }
run() { printf '%s;\ncommit;\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1; }
both() { # <label> <statement>
    seed
    run "127.0.0.1/3050:$ENG" "$2"; local e=$(final "127.0.0.1/3050:$ENG")
    run "127.0.0.1/$PORT:$FC" "$2"; local f=$(final "127.0.0.1/$PORT:$FC")
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }
}

M="merge into t using (select id from t) s on t.id=s.id when matched then update set"
both "SUM set (Halloween)"     "$M n=(select sum(n) from t)"
both "n + SUM"                 "$M n=n+(select sum(n) from t)"
both "COUNT set"               "$M n=(select count(*) from t)"
both "MAX set"                 "$M n=(select max(n) from t)"
both "correlated forward"      "$M n=(select n from t t2 where t2.id=t.id+1)"
both "set from source"         "merge into t using (select id, id*100 v from t) s on t.id=s.id when matched then update set n=s.v"
both "n = n + 1 (no subq)"     "$M n=n+1"
both "not-matched insert sum"  "merge into t using (select 4 id from rdb\$database union all select 5 from rdb\$database) s on t.id=s.id when not matched then insert (id,n) values (s.id,(select sum(n) from t))"
both "plain UPDATE (control)"  "update t set n=(select sum(n) from t)"
both "delete below avg (ctl)"  "delete from t where n < (select avg(n) from t)"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS mergesnap" || echo "FAIL mergesnap"
exit $fail
