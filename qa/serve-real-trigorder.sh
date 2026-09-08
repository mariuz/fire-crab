#!/bin/bash
# TRIGGERS FIRE IN POSITION ORDER, and among triggers that SHARE a
# position, in CATALOG/CREATION order - not alphabetically by name.
#
# fire-crab collected a table's triggers in creation order then re-sorted
# them by (position, NAME), forcing an alphabetical tiebreak the engine
# does not use. A BEFORE trigger runs its body per row, so the order
# decides the final NEW value: three BEFORE INSERT triggers at position 0
# created za_t/mb_t/ac_t (each appending Z/M/A) yield 'ZMA' on the engine
# (creation order) but 'AMZ' under a name sort - a silent wrong stored
# value. The fix drops the name tiebreak; the collection is already in
# creation order and the sort is stable, so equal positions keep creation
# order. (The engine's same-position order is formally unspecified, but
# for triggers created in sequence it is creation order, which this now
# matches.)
#
# Both servers run the same DDL+DML over their own copies; the resulting
# stored value must agree.
#
# Usage: qa/serve-real-trigorder.sh [port]   (default 4140)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4140}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/trigorder-eng.fdb"; FC="$D/trigorder-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/trigorder-build.log 2>&1 <<'SQL'
create table samep (id integer primary key, s varchar(40));
commit;
set term ^;
create trigger za_t for samep before insert position 0 as begin new.s = new.s || 'Z'; end^
create trigger mb_t for samep before insert position 0 as begin new.s = new.s || 'M'; end^
create trigger ac_t for samep before insert position 0 as begin new.s = new.s || 'A'; end^
set term ;^
commit;
create table posn (id integer primary key, s varchar(40));
commit;
set term ^;
create trigger p_c for posn before insert position 8 as begin new.s = new.s || 'C'; end^
create trigger p_a for posn before insert position 2 as begin new.s = new.s || 'A'; end^
create trigger p_b for posn before insert position 5 as begin new.s = new.s || 'B'; end^
set term ;^
commit;
-- a fourth same-position pair created in reverse-alpha order, to show
-- the order tracks CREATION, not name
create table samep2 (id integer primary key, s varchar(40));
commit;
set term ^;
create trigger z_first for samep2 before insert position 0 as begin new.s = new.s || 'F'; end^
create trigger a_second for samep2 before insert position 0 as begin new.s = new.s || 'S'; end^
set term ;^
commit;
SQL
if grep -qi error /tmp/trigorder-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/trigorder-build.log; exit 1; fi
cp "$ENG" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-trigorder.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
both() { # <label> <table> <insert+select>
    local a b
    a=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" <<< "$3" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" <<< "$3" 2>&1 | sed 's/[[:space:]]*$//')
    if [ "$a" = "$b" ]; then echo "OK   $1 [$(printf '%s' "$a" | tr -d ' \n' | sed 's/S//')]"; else echo "FAIL $1"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -6 | sed 's/^/     /'; fail=1; fi
}
both "same-position BEFORE triggers fire in creation order" samep \
     "insert into samep (id,s) values (1,''); select s from samep;"
both "distinct positions fire in position order" posn \
     "insert into posn (id,s) values (1,''); select s from posn;"
both "same-position order is creation, not name (reverse-alpha names)" samep2 \
     "insert into samep2 (id,s) values (1,''); select s from samep2;"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS trigorder" || echo "FAIL trigorder"
exit $fail
