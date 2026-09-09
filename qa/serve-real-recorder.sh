#!/bin/bash
# A RECURSIVE CTE WITH FIRST/SKIP/ROWS BUT NO ORDER BY IS REFUSED.
#
# The engine walks a WITH RECURSIVE depth-first in RECORD-NUMBER
# (storage) order; fire-crab walks it breadth-first (a level queue). The
# two produce the SAME SET but a different ORDER, and a top-level
# FIRST/SKIP/ROWS then slices a DIFFERENT SET OF ROWS - measured: FIRST 3
# of a tree walk is the engine's {1, 1/2, 1/2/4} against fire-crab's
# {1, 1/2, 1/3}. fire-crab has no record-number model, so it cannot
# reproduce the engine's sibling order; a stack would only trade one
# wrong order for another. A top-level ORDER BY over a key makes the two
# agree (byte-identical, measured), so that path stays open; a limited
# recursive result WITHOUT an ORDER BY is a confident wrong rowset, so
# fire-crab REFUSES it. The unlimited walk (order-only difference, same
# set) and DISTINCT (order-independent) stay answering.
#
# Usage: qa/serve-real-recorder.sh [port]   (default 4154)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4154}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/recorder.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/recorder-build.log 2>&1 <<'SQL'
create table tree (id int primary key, parent_id int);
commit;
insert into tree values (1,null);insert into tree values (2,1);insert into tree values (3,1);
insert into tree values (4,2);insert into tree values (5,2);insert into tree values (6,3);insert into tree values (7,3);
commit;
SQL
if grep -qi error /tmp/recorder-build.log; then echo "FAIL fixture:"; sed 's/^/  /' /tmp/recorder-build.log; exit 1; fi
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-recorder.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }
E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
CTE="with recursive r(id,depth,path) as (select id,0,cast(id as varchar(50)) from tree where parent_id is null union all select tr.id,r.depth+1,r.path||'/'||tr.id from tree tr join r on tr.parent_id=r.id)"
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "ERR"; else printf '%s' "$r" | grep -iE '^(PATH|X|ID) ' | tr '\n' ',' | sed 's/ //g'; fi; }
refuse() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    { [ "$e" != "ERR" ] && [ "$f" = "ERR" ]; } && echo "OK   refuse $1 (engine answers, fc refuses)" || { echo "FAIL refuse $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
agree() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
echo "-- GUARD: FIRST/SKIP/ROWS without a top-level ORDER BY -> fc refuses --"
refuse "FIRST 3 no order"   "$CTE select first 3 path from r;"
refuse "ROWS 3 TO 5 no order" "$CTE select path from r rows 3 to 5;"
refuse "SKIP-form ROWS 3 no order" "$CTE select path from r rows 3;"
echo "-- OPEN: a top-level ORDER BY makes engine and fc agree --"
agree "FIRST 3 ORDER BY path" "$CTE select first 3 path from r order by path;"
agree "ROWS 3 TO 5 ORDER path" "$CTE select path from r order by path rows 3 to 5;"
echo "-- OPEN: unlimited walk with ORDER BY, and a linear numbers series --"
agree "full walk ORDER path"  "$CTE select path from r order by path;"
agree "numbers 1..10"         "with recursive n(x) as (select 1 from rdb\$database union all select x+1 from n where x<10) select x from n;"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS recorder" || echo "FAIL recorder"
exit $fail
