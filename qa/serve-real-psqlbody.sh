#!/bin/bash
# A TRIGGER OR PROCEDURE BODY RUNS ITS STATEMENTS EVEN WHEN A STATEMENT
# HOLDS A CONSTRUCT THE ARITHMETIC BODY-GRAMMAR CANNOT REPRESENT.
#
# fire-crab's trigger/procedure fire path re-parses the body SOURCE and
# interprets it. Three gaps used to make a runnable body refuse or
# mis-answer, all fixed here and pinned against the engine:
#
#  * an EMPTY body ('begin end') parsed to no statements and the whole
#    block was rejected, so ANY dml on a table carrying an empty trigger
#    failed. An empty body is now a valid no-op, as the engine treats it.
#
#  * an assignment whose right side is a CONDITIONAL (COALESCE / CASE) -
#    which the arithmetic body-grammar can't hold - made the body refuse.
#    The right side is now kept as written and evaluated through the
#    query planner at fire time, so NEW.r = COALESCE(NEW.v,-1) and a
#    CASE assignment produce the engine's stored value.
#
#  * a procedure statement reading a SUBQUERY (a running SUM after its own
#    INSERT, or a COUNT over a system table) is evaluated the same way.
#
# The engine builds each fixture and it is copied byte-identically; the
# DML+SELECT result through the engine and through fire-crab must agree.
#
# Note: a CONDITIONAL body created THROUGH fire-crab is still refused at
# CREATE (fire-crab will not emit BLR it cannot round-trip); this gate
# builds such triggers on the engine, which is the path a restore uses.
#
# Usage: qa/serve-real-psqlbody.sh [port]   (default 4141)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4141}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/psqlbody-eng.fdb"; FC="$D/psqlbody-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/psqlbody-build.log 2>&1 <<'SQL'
create table tc (v integer, r integer);
create table te (v integer, r integer);
create table tcase (v integer, r integer);
commit;
set term ^;
create trigger tc_bi for tc before insert as begin new.r = coalesce(new.v, -1); end^
create trigger te_bi for te before insert as begin end^
create trigger tcase_bi for tcase before insert as
  begin new.r = case when new.v is null then -1 when new.v > 10 then 100 else new.v end; end^
set term ;^
commit;
create table t_acc (v integer);
create table t_acc_log (tot integer);
commit;
set term ^;
create procedure p_acc (pv integer) as declare tot integer;
  begin insert into t_acc (v) values (:pv); tot = (select sum(v) from t_acc);
        insert into t_acc_log (tot) values (:tot); end^
create procedure p_sys returns (c integer) as
  begin c = (select count(*) from rdb$relations); suspend; end^
set term ;^
commit;
SQL
if grep -qi error /tmp/psqlbody-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/psqlbody-build.log; exit 1; fi
cp "$ENG" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-psqlbody.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
both() { # <label> <script>
    local a b
    a=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" <<< "$2" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" <<< "$2" 2>&1 | sed 's/[[:space:]]*$//')
    if [ "$a" = "$b" ]; then echo "OK   $1"; else echo "FAIL $1"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -10 | sed 's/^/     /'; fail=1; fi
}
both "COALESCE assignment in a BEFORE trigger stores the engine's value" \
     "insert into tc(v) values(5); insert into tc(v) values(null); insert into tc(v) values(20); select v,r from tc order by v nulls last;"
both "an empty trigger body is a no-op and does not block the INSERT" \
     "insert into te(v) values(9); select count(*) from te;"
both "CASE assignment in a BEFORE trigger stores the engine's value" \
     "insert into tcase(v) values(5); insert into tcase(v) values(20); select v,r from tcase order by v;"
both "a procedure subquery reads its own prior INSERT (running SUM)" \
     "execute procedure p_acc(10); execute procedure p_acc(5); select tot from t_acc_log order by tot;"
both "a procedure subquery over a system table returns the engine's count" \
     "select c from p_sys;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS psqlbody" || echo "FAIL psqlbody"
exit $fail
