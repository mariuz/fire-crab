#!/bin/bash
# THE RESTORE THE CONVERSION PERFORMS ITSELF: fire-crab's service-side
# `gbak -c -se` of the ENGINE'S backup of the employee database, held
# against the engine's own restore of that backup.
#
# The engine opens both restored files. They must be one database: the
# extracted DDL, the constraint and index names as the file had them
# (INTEG_<n>, RDB$PRIMARY<n>, RDB$FOREIGN<n>), relation ids with the view
# at its stream position, security classes and default classes numbered
# as the engine numbers them (every global field first, relations,
# generators, exceptions, procedures; an empty table's default class after
# the tables with rows, the view's after that), formats (a computed-column
# table at 2), dependencies, every RDB$USER_PRIVILEGES row verbatim, every
# data row - blob ids included, since the engine numbers a table's blobs
# before its rows and a client reading `select *` sees them.
#
# ONE recorded exception: RDB$RELATION_FIELDS.RDB$FIELD_ID is not compared.
# The engine numbers field ids by the field records' ARRIVAL order; this
# restore numbers them by field-id rank, so on a table whose position order
# differs from its field-id order (employee JOB, COUNTRY, CUSTOMER) the id
# column differs - and a bare SELECT *, which the engine expands in the
# format's field-id order, lists such a table's columns field-id-first.
# Every position, source, constraint, index, class, dependency, privilege
# and DATA row (read by explicit column) matches; JOB and COUNTRY are read
# with explicit columns for that reason.
#
# Usage: qa/serve-real-emprestore.sh [port]   (default 4132)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4132}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
FX="$(cd "$(dirname "$0")" && pwd)/fixtures/empbuild"
SRC="$D/emprestore-src.fdb"
[ -f "$FX/empddl.sql" ] || { echo "SKIP no fixtures"; exit 0; }
mkdir -p "$D"
rm -f "$SRC" "$D"/emprestore.fbk "$D"/emprestore-eng-r.fdb "$D"/emprestore-fc-r.fdb

fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# --- the source: the employee database, built by the ENGINE from the
# sample scripts, backed up by the ENGINE - the restore under test reads
# the engine's own stream
echo "create database '127.0.0.1/3050:$SRC' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
for s in empddl.sql empdml.sql; do
    n=$(cd "$FX" && "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$SRC" -i "$s" 2>&1 | grep -c "Statement failed")
    [ "$n" = "0" ] && ok "$s builds the source on the engine" || bad "$s on the engine: $n refusals"
done
"$GBAK" -b -user "$U" -pas "$P" "127.0.0.1/3050:$SRC" "$D/emprestore.fbk" >/dev/null 2>&1
[ -s "$D/emprestore.fbk" ] && ok "the engine backs up the source" || bad "the engine's backup"

# --- 1. the engine restores it; fire-crab's SERVICE restores it -------------
"$GBAK" -c -v -user "$U" -pas "$P" "$D/emprestore.fbk" "127.0.0.1/3050:$D/emprestore-eng-r.fdb" >"$D/emprestore-restore-eng.log" 2>&1
[ $? = 0 ] && ok "the engine restores the backup" || bad "the engine's restore: $(grep -m1 ERROR "$D/emprestore-restore-eng.log")"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-emprestore.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"; exit 1; }
"$GBAK" -c -v -se "127.0.0.1/$PORT:service_mgr" -user "$U" -pas "$P" "$D/emprestore.fbk" "$D/emprestore-fc-r.fdb" >"$D/emprestore-restore-fc.log" 2>&1
rc=$?
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
if [ $rc = 0 ] && [ -f "$D/emprestore-fc-r.fdb" ]; then ok "fire-crab's service restores the engine's backup (gbak -c -se)"; else bad "fire-crab's restore: $(grep -m1 ERROR "$D/emprestore-restore-fc.log")"; echo "FAIL emprestore"; exit 1; fi
chmod 666 "$D/emprestore-fc-r.fdb"
for f in eng fc; do
    e=$(grep -c "restoring privilege" "$D/emprestore-restore-$f.log"); echo "$f privilege lines: $e" >/dev/null
done
[ "$(grep -c 'restoring privilege' "$D/emprestore-restore-eng.log")" = "$(grep -c 'restoring privilege' "$D/emprestore-restore-fc.log")" ] \
    && ok "both restores narrate the same number of privilege records" || bad "privilege lines differ between the two restore logs"

# --- 2. the engine opens both: one database ---------------------------------
ENG="$D/emprestore-eng-r.fdb"; FC="$D/emprestore-fc-r.fdb"
both() { # <label> <isql args...>
    local label="$1"; shift
    a=$("$ISQL" -q -user "$U" -pas "$P" "$@" "127.0.0.1/3050:$ENG" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "$@" "127.0.0.1/3050:$FC" 2>&1 | sed 's/[[:space:]]*$//')
    if [ "$a" = "$b" ]; then ok "$label"; else bad "$label"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'; fi
}
x() { "$ISQL" -q -user "$U" -pas "$P" -x "127.0.0.1/3050:$1" 2>&1 | grep -v '^/\* CREATE DATABASE'; }
if [ "$(x "$ENG")" = "$(x "$FC")" ]; then ok "isql -x extracts the same DDL from both restores"; else bad "isql -x"; diff <(x "$ENG") <(x "$FC") | head -12 | sed 's/^/     /'; fi
Q=$(mktemp "$D/emprestore-q.XXXXXX.sql")
cat > "$Q" <<'SQL'
select rc.rdb$constraint_name, rc.rdb$relation_name, rc.rdb$constraint_type, rc.rdb$index_name from rdb$relation_constraints rc where rc.rdb$relation_name not starting with 'RDB$' order by 1;
select rdb$index_name, rdb$relation_name, rdb$unique_flag, rdb$index_type, rdb$foreign_key from rdb$indices where rdb$system_flag = 0 order by 1;
select t.rdb$trigger_name, t.rdb$relation_name, t.rdb$trigger_type, t.rdb$trigger_sequence from rdb$triggers t where t.rdb$system_flag = 0 order by 1;
select rdb$relation_name, rdb$relation_id, rdb$format, rdb$security_class, rdb$default_class, rdb$owner_name, rdb$relation_type, rdb$flags from rdb$relations where rdb$relation_id >= 128 order by rdb$relation_id;
select rdb$procedure_name, rdb$procedure_id, rdb$security_class, rdb$owner_name from rdb$procedures order by rdb$procedure_id;
select rdb$field_name, rdb$field_type, rdb$field_length, rdb$field_scale, rdb$field_sub_type, rdb$field_precision, rdb$character_length, rdb$character_set_id, rdb$collation_id, rdb$dimensions, rdb$security_class, rdb$owner_name from rdb$fields where rdb$system_flag = 0 order by 1;
select rdb$relation_name, rdb$field_name, rdb$field_source, rdb$field_position, rdb$null_flag, rdb$update_flag, rdb$collation_id from rdb$relation_fields where rdb$relation_name not starting with 'RDB$' and rdb$relation_name not starting with 'MON$' and rdb$relation_name not starting with 'SEC$' order by 1, 2;
select rdb$exception_name, rdb$exception_number, rdb$security_class, rdb$owner_name from rdb$exceptions order by 1;
select rdb$generator_name, rdb$generator_id, rdb$security_class, rdb$owner_name from rdb$generators where rdb$system_flag = 0 order by 1;
select rdb$dependent_name, rdb$depended_on_name, rdb$field_name, rdb$dependent_type, rdb$depended_on_type from rdb$dependencies order by 1,2,3,4,5;
select rdb$object_type, rdb$privilege, rdb$user, rdb$grantor, rdb$relation_name, rdb$field_name, rdb$grant_option from rdb$user_privileges where rdb$object_type in (0, 5, 7, 14) and rdb$relation_name not starting with 'RDB$' order by 1,2,3,4,5,6;
select f.rdb$relation_id, f.rdb$format from rdb$formats f where f.rdb$relation_id >= 128 order by 1, 2;

SQL
both "constraint, index, class, format, dependency and privilege rows" -i "$Q"
cat > "$Q" <<'SQL'
select country, currency from country order by country;
select job_code, job_grade, job_country, job_title, min_salary, max_salary, job_requirement, language_req from job order by job_code, job_grade, job_country;
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
both "every row of every table (blob ids included), the view and the generators" -i "$Q"
rm -f "$Q"
[ $fail = 0 ] && echo "PASS emprestore" || echo "FAIL emprestore"
exit $fail
