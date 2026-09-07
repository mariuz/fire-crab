#!/bin/bash
# THE LOGICAL BACKUP OF THE EMPLOYEE DATABASE: fire-crab's `gbak -b` of the
# employee file the empbuild fixtures produce, held against THE ENGINE'S
# `gbak -b` OF THE SAME FILE.
#
# No check compares the two .fbk byte for byte - relation order in a backup
# is the file's physical RDB$RELATIONS order, timestamps ride in the
# header, and the engine's stream is compressed differently. The criterion
# is what the REAL gbak makes of each: the engine restores both backups,
# and the two restored databases must be the same database - `isql -x`
# extracts the same DDL, the catalog answers the same generated names,
# ids, security classes, dependencies, privileges and formats, every row
# of every table reads the same, and the engine's restore synthesised no
# privilege of its own ("adding missing privileges" grants USAGE to PUBLIC
# on any domain or exception whose record arrives without its owner - the
# difference that once put twenty grants in one restore and none in the
# other).
#
# Usage: qa/serve-real-empbackup.sh [port]   (default 4131)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4131}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
FX="$(cd "$(dirname "$0")" && pwd)/fixtures/empbuild"
SRC="$D/empbackup-src.fdb"
[ -f "$FX/empddl.sql" ] || { echo "SKIP no fixtures"; exit 0; }
mkdir -p "$D"
rm -f "$SRC" "$D"/empbackup-eng.fbk "$D"/empbackup-fc.fbk "$D"/empbackup-eng-r.fdb "$D"/empbackup-fc-r.fdb

fail=0
ok() { echo "OK   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# --- the source: the employee database, built THROUGH fire-crab from the
# sample scripts (the same build the empbuild gate holds against the engine)
echo "create database '127.0.0.1/3050:$SRC' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-empbackup.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"; exit 1; }
for s in empddl.sql empdml.sql; do
    n=$(cd "$FX" && "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$SRC" -i "$s" 2>&1 | grep -c "Statement failed")
    if [ "$n" = "0" ]; then ok "$s builds the source through fire-crab"; else bad "$s through fire-crab: $n refusals"; fi
done

# --- 1. both servers back up THE SAME FILE ---------------------------------
"$GBAK" -b -user "$U" -pas "$P" "127.0.0.1/3050:$SRC" "$D/empbackup-eng.fbk" >/dev/null 2>&1
[ -s "$D/empbackup-eng.fbk" ] && ok "the engine backs up the source" || bad "the engine's backup"
"$GBAK" -b -se "127.0.0.1/$PORT:service_mgr" -user "$U" -pas "$P" "$SRC" "$D/empbackup-fc.fbk" >/dev/null 2>&1
[ -s "$D/empbackup-fc.fbk" ] && ok "fire-crab backs up the same file (gbak -b -se)" || bad "fire-crab's backup"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT

# --- 2. the REAL gbak restores both --------------------------------------------
for f in eng fc; do
    "$GBAK" -c -v -user "$U" -pas "$P" "$D/empbackup-$f.fbk" "127.0.0.1/3050:$D/empbackup-$f-r.fdb" >"$D/empbackup-restore-$f.log" 2>&1
    if [ $? = 0 ]; then ok "the real gbak -c restores the $f backup"; else bad "gbak -c of the $f backup: $(grep -m1 ERROR "$D/empbackup-restore-$f.log")"; fi
done
e=$(grep -c "restoring privilege" "$D/empbackup-restore-eng.log"); f=$(grep -c "restoring privilege" "$D/empbackup-restore-fc.log")
[ "$e" = "$f" ] && ok "both restores replay the same number of privilege records [$e]" || bad "privilege records replayed: engine $e, fire-crab $f"
for f in eng fc; do
    if grep -q "error accessing BLOB\|ERROR" "$D/empbackup-restore-$f.log"; then bad "the $f restore logged an error"; else ok "the $f restore logged no error"; fi
done

# --- 3. the two restored databases are the same database -------------------
ENG="$D/empbackup-eng-r.fdb"; FC="$D/empbackup-fc-r.fdb"
both() { # <label> <isql args...>
    local label="$1"; shift
    a=$("$ISQL" -q -user "$U" -pas "$P" "$@" "127.0.0.1/3050:$ENG" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "$@" "127.0.0.1/3050:$FC" 2>&1 | sed 's/[[:space:]]*$//')
    if [ "$a" = "$b" ]; then ok "$label"; else bad "$label"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'; fi
}
x() { "$ISQL" -q -user "$U" -pas "$P" -x "127.0.0.1/3050:$1" 2>&1 | grep -v '^/\* CREATE DATABASE'; }
if [ "$(x "$ENG")" = "$(x "$FC")" ]; then ok "isql -x extracts the same DDL from both restores"; else bad "isql -x"; diff <(x "$ENG") <(x "$FC") | head -12 | sed 's/^/     /'; fi
Q=$(mktemp "$D/empbackup-q.XXXXXX.sql")
cat > "$Q" <<'SQL'
select rc.rdb$constraint_name, rc.rdb$relation_name, rc.rdb$constraint_type, rc.rdb$index_name from rdb$relation_constraints rc where rc.rdb$relation_name not starting with 'RDB$' order by 1;
select t.rdb$trigger_name, t.rdb$relation_name, t.rdb$trigger_type from rdb$triggers t where t.rdb$system_flag = 0 order by 1;
select rdb$relation_name, rdb$relation_id, rdb$format, rdb$security_class, rdb$default_class, rdb$owner_name from rdb$relations where rdb$relation_id >= 128 order by rdb$relation_id;
select rdb$procedure_name, rdb$procedure_id, rdb$security_class, rdb$owner_name from rdb$procedures order by rdb$procedure_id;
select rdb$field_name, rdb$field_type, rdb$field_length, rdb$field_scale, rdb$field_sub_type, rdb$field_precision, rdb$character_length, rdb$security_class, rdb$owner_name from rdb$fields where rdb$system_flag = 0 order by 1;
select rdb$exception_name, rdb$exception_number, rdb$security_class, rdb$owner_name from rdb$exceptions order by 1;
select rdb$generator_name, rdb$generator_id, rdb$security_class, rdb$owner_name from rdb$generators where rdb$system_flag = 0 order by 1;
select rdb$dependent_name, rdb$depended_on_name, rdb$field_name, rdb$dependent_type, rdb$depended_on_type from rdb$dependencies order by 1,2,3,4,5;
select rdb$object_type, rdb$privilege, rdb$user, rdb$grantor, rdb$relation_name, rdb$field_name, rdb$grant_option from rdb$user_privileges order by 1,2,3,4,5,6;
select f.rdb$relation_id, f.rdb$format from rdb$formats f where f.rdb$relation_id >= 128 order by 1, 2;
SQL
both "generated names, ids, classes, owners, dependencies, privileges, formats" -i "$Q"
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
[ $fail = 0 ] && echo "PASS empbackup" || echo "FAIL empbackup"
exit $fail
