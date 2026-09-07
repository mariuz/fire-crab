#!/bin/bash
# serve-real-empbuild.sh - THE EMPLOYEE DATABASE BUILDS THROUGH fire-crab
# from its own scripts (Firebird's examples/empbuild/empddl.sql and
# empdml.sql, kept under qa/fixtures/empbuild), and what it builds is
# what the engine builds: the same DDL back out (`isql -x`), the same
# generated names in the same order (INTEG_n, RDB$PRIMARYn / RDB$n /
# RDB$FOREIGNn, CHECK_n, SQL$n, SQL$DEFAULTn), the same relation ids,
# formats, dependency rows, privileges and data.
#
# Both databases are CREATED by the engine (empty); the engine then runs
# the scripts against one, fire-crab against the other; the engine reads
# both back for every comparison, so the FILES are what is compared.
#
# usage: qa/serve-real-empbuild.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4127}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
FX="$(cd "$(dirname "$0")" && pwd)/fixtures/empbuild"
ENG="$D/empbuild-eng.fdb"; FC="$D/empbuild-fc.fdb"
[ -f "$FX/empddl.sql" ] || { echo "SKIP no fixtures"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
for f in "$ENG" "$FC"; do
    echo "create database '127.0.0.1/3050:$f' user '$U' password '$P' page_size 8192 default character set NONE;" \
        | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $f"; exit 1; }
done
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-empbuild.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"; exit 1; }
fail=0
run() { # <server db> <script> -> failure count
    (cd "$FX" && "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$2" 2>&1 | grep -c "Statement failed")
}
check_count() { # <label> <want> <got>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1: want $2, got $3"; fail=1; fi
}
check_count "empddl.sql runs clean on the engine"    0 "$(run "127.0.0.1/3050:$ENG" empddl.sql)"
check_count "empddl.sql runs clean through fire-crab" 0 "$(run "127.0.0.1/$PORT:$FC" empddl.sql)"
check_count "empdml.sql runs clean on the engine"    0 "$(run "127.0.0.1/3050:$ENG" empdml.sql)"
check_count "empdml.sql runs clean through fire-crab" 0 "$(run "127.0.0.1/$PORT:$FC" empdml.sql)"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
# --- the engine reads both files -----------------------------------
both() { # <label> <isql args...>
    local label="$1"; shift
    a=$("$ISQL" -q -user "$U" -pas "$P" "$@" "127.0.0.1/3050:$ENG" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "$@" "127.0.0.1/3050:$FC" 2>&1 | sed 's/[[:space:]]*$//')
    if [ "$a" = "$b" ]; then echo "OK   $label"; else echo "DIFF $label"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'; fail=1; fi
}
x() { "$ISQL" -q -user "$U" -pas "$P" -x "127.0.0.1/3050:$1" 2>&1 | grep -v '^/\* CREATE DATABASE'; }
if [ "$(x "$ENG")" = "$(x "$FC")" ]; then echo "OK   isql -x extracts the same DDL from both"; else echo "DIFF isql -x"; diff <(x "$ENG") <(x "$FC") | head -12 | sed 's/^/     /'; fail=1; fi
Q=$(mktemp "$D/empbuild-q.XXXXXX.sql")
cat > "$Q" <<'SQL'
select rc.rdb$constraint_name, rc.rdb$relation_name, rc.rdb$constraint_type, rc.rdb$index_name from rdb$relation_constraints rc where rc.rdb$relation_name not starting with 'RDB$' order by cast(substring(rc.rdb$constraint_name from 7) as integer);
select t.rdb$trigger_name, t.rdb$relation_name, t.rdb$trigger_type from rdb$triggers t where t.rdb$trigger_name starting with 'CHECK_' order by cast(substring(t.rdb$trigger_name from 7) as integer);
select rdb$relation_name, rdb$relation_id, rdb$format, rdb$security_class, rdb$default_class from rdb$relations where rdb$relation_id >= 128 order by rdb$relation_id;
select rdb$procedure_name, rdb$procedure_id, rdb$security_class from rdb$procedures order by rdb$procedure_id;
select rdb$field_name, rdb$field_type, rdb$field_length, rdb$field_scale, rdb$field_sub_type, rdb$field_precision, rdb$character_length, rdb$security_class from rdb$fields where rdb$system_flag = 0 order by rdb$field_name;
select rdb$dependent_name, rdb$depended_on_name, rdb$field_name, rdb$dependent_type, rdb$depended_on_type from rdb$dependencies order by 1,2,3,4,5;
select rdb$object_type, rdb$privilege, rdb$user, rdb$relation_name, rdb$grant_option from rdb$user_privileges where rdb$relation_name not starting with 'RDB$' and rdb$relation_name not starting with 'SEC$' and rdb$relation_name not starting with 'MON$' order by 1,2,3,4,5;
select f.rdb$relation_id, f.rdb$format from rdb$formats f where f.rdb$relation_id >= 128 order by 1, 2;
SQL
both "generated names, ids, classes, dependencies, privileges, formats" -i "$Q"
cat > "$Q" <<'SQL'
select * from country order by country;
select * from job order by job_code, job_grade, job_country;
select * from department order by dept_no;
select * from employee order by emp_no;
select * from project order by proj_id;
select * from employee_project order by emp_no, proj_id;
select * from proj_dept_budget order by fiscal_year, proj_id, dept_no;
select emp_no, updater_id, old_salary, percent_change, new_salary from salary_history order by emp_no, old_salary, percent_change;
select * from customer order by cust_no;
select po_number, cust_no, sales_rep, order_status, order_date, date_needed, paid, qty_ordered, total_value, discount, item_type from sales order by po_number;
select * from phone_list order by emp_no;
select gen_id(emp_no_gen, 0), gen_id(cust_no_gen, 0) from rdb$database;
SQL
both "every row of every table, the view and the generators" -i "$Q"
rm -f "$Q"
exit $fail
