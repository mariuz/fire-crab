#!/bin/bash
# A RECURSIVE CTE WITH FIRST/SKIP/ROWS AND NO ORDER BY IS ANSWERED, AND
# IT AGREES WITH THE ENGINE ROW FOR ROW.
#
# HISTORY (this gate used to record the opposite).  The engine walks a
# WITH RECURSIVE depth-first in RECORD-NUMBER (storage) order.  fire-crab
# used to walk it breadth-first (a level queue): same SET, different
# ORDER, so a top-level FIRST/SKIP/ROWS sliced a DIFFERENT SET OF ROWS -
# measured then as the engine's {1, 1/2, 1/2/4} against fire-crab's
# {1, 1/2, 1/3}.  Because that is a confident wrong rowset, fire-crab
# REFUSED the limited-without-ORDER-BY shape and the three cells below
# were recorded as refusals.
#
# PROMOTED 2026-09-20.  fire-crab now walks the recursion depth-first in
# record-number order and the refusals are gone, so all three cells are
# now ordinary agreement cells.  Measured on this fixture: FIRST 3 is
# {1, 1/2, 1/2/4} on BOTH sides, ROWS 3 TO 5 is {1/2/4, 1/2/5, 1/3} on
# BOTH sides, and the unlimited walk is byte-identical.
#
# The gap was closed by an EARLIER chunk, not by the change in the tree
# when this was promoted: /tmp/fcwire-prev-0e5a8f4 (the previous
# committed binary) answers all three identically, so these cells are
# green on the previous binary too and carry no teeth for that change.
#
# The order really is RECORD-NUMBER order, not the id order this
# fixture happens to insert in.  Boundary probe on 2026-09-20, a twin
# tree inserted in the order 3,7,1,6,2,5,4: engine and fire-crab BOTH
# return 1, 1/3, 1/3/7, 1/3/6, 1/2, 1/2/5, 1/2/4 for the unlimited walk
# and BOTH return {1, 1/3, 1/3/7} for FIRST 3 - i.e. both follow storage
# order away from id order, together.  A top-level ORDER BY over a key
# still makes the two agree, and those cells stay as they were.
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
E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0; ran=0
CTE="with recursive r(id,depth,path) as (select id,0,cast(id as varchar(50)) from tree where parent_id is null union all select tr.id,r.depth+1,r.path||'/'||tr.id from tree tr join r on tr.parent_id=r.id)"
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "ERR"; else printf '%s' "$r" | grep -iE '^(PATH|X|ID) ' | tr '\n' ',' | sed 's/ //g'; fi; }
refuse() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    { [ "$e" != "ERR" ] && [ "$f" = "ERR" ]; } && echo "OK   refuse $1 (engine answers, fc refuses)" || { echo "FAIL refuse $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
agree() { local e f; ran=$((ran + 1)); e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
# PROMOTED 2026-09-20: these three were `refuse` cells (fire-crab walked the
# recursion breadth-first, so a limited slice picked different rows).  All
# three now agree with the engine row for row, on the working tree AND on the
# previous committed binary /tmp/fcwire-prev-0e5a8f4 - the depth-first
# record-number walk landed in an earlier chunk and nobody unrecorded it.
echo "-- OPEN: FIRST/SKIP/ROWS with no top-level ORDER BY - record-number walk --"
agree "FIRST 3 no order"   "$CTE select first 3 path from r;"
agree "ROWS 3 TO 5 no order" "$CTE select path from r rows 3 to 5;"
agree "SKIP-form ROWS 3 no order" "$CTE select path from r rows 3;"
echo "-- OPEN: a top-level ORDER BY makes engine and fc agree --"
agree "FIRST 3 ORDER BY path" "$CTE select first 3 path from r order by path;"
agree "ROWS 3 TO 5 ORDER path" "$CTE select path from r order by path rows 3 to 5;"
echo "-- OPEN: unlimited walk with ORDER BY, and a linear numbers series --"
agree "full walk ORDER path"  "$CTE select path from r order by path;"
agree "numbers 1..10"         "with recursive n(x) as (select 1 from rdb\$database union all select x+1 from n where x<10) select x from n;"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
# THE FLOOR IS COUNTED FROM A MEASURED RUN, never typed: 7 cells on
# 2026-09-20.  A pass/fail tally cannot see a cell that STOPS RUNNING -
# an early exit, a helper renamed, a fixture that failed to load - and a
# cell that measures nothing reads exactly like one that passes.
if [ "$ran" -lt 7 ]; then
    echo "FAIL only $ran checks ran; 7 were measured - cells went missing"
    fail=1
fi
echo "ran $ran checks"
[ $fail = 0 ] && echo "PASS recorder" || echo "FAIL recorder"
exit $fail
