#!/bin/bash
# FIRST / SKIP AROUND A UNION, AND THE LIMIT CLAUSES THAT CANNOT MEET.
#
# Measured on engine 2182 and matched:
#
#   * a UNION member's FIRST/SKIP is THAT MEMBER'S. `select first 2 a
#     from t1 union all select x from t2` is two rows of T1 and every row
#     of T2 (and the same eight under a trailing ORDER BY). This server
#     peeled the FIRST off the statement head before it split the union
#     and cut the WHOLE result to two rows.
#   * ROWS / OFFSET / FETCH after the last member belong to the union, and
#     a member's FIRST beside them is fine (`... rows 3` answers 10,20,5).
#   * FIRST/SKIP and ROWS/OFFSET/FETCH on the SAME query spec are -104
#     "FIRST/SKIP cannot be used with OFFSET/FETCH or ROWS" - at the top,
#     in a derived table, a scalar / EXISTS subquery, a CTE's main query
#     and an INSERT's source. This server let the ROWS clause win (and the
#     INSERT inserted its row). An unknown TABLE's -204 outranks it, an
#     unknown column does not.
#   * ORDER BY / ROWS / OFFSET / FETCH on a member that is not the last is
#     the parser's -104 "Token unknown" at the UNION that follows - the
#     token as written, the column in BYTES. ROWS and OFFSET/FETCH are
#     one slot: the second of them (or one after WITH LOCK) is the
#     unknown token. This server answered the union, or a bare refusal.
#
# Usage: qa/serve-real-unionlimit.sh [port]   (default 5340)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5340}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/unionlimit-eng.fdb"; FC="$D/unionlimit-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
create table t1 (id integer not null primary key, a integer, v varchar(20));
create table t2 (id integer not null primary key, x integer, s varchar(20));
create table t3 (k integer, name varchar(10));
insert into t1 values (1, 10, 'apple');
insert into t1 values (2, 20, 'banana');
insert into t1 values (3, null, 'cherry');
insert into t1 values (4, 10, null);
insert into t1 values (5, 30, 'a_b%c');
insert into t1 values (6, 20, 'Apple');
insert into t2 values (1, 5, 'one');
insert into t2 values (2, 6, 'two');
insert into t2 values (3, null, 'three');
insert into t2 values (4, 8, null);
insert into t2 values (5, 9, 'five');
insert into t2 values (6, 10, 'six');
insert into t3 values (1, 'x');
insert into t3 values (2, 'y');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/unionlimit-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/unionlimit-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/unionlimit-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-unionlimit-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the engine ANSWERS and this server REFUSES - recorded, never faked
refused() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" != "$ev" ]; then echo "FAIL $1 - the engine raises [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS; promote the cell"; fail=1
    elif [ "${fv#Statement failed}" = "$fv" ]; then echo "FAIL $1 - answers WRONG: eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 (recorded: engine answers [${ev:0:60}], this server refuses)"; fi
}
FS='Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-FIRST/SKIP cannot be used with OFFSET/FETCH or ROWS'
tok() { echo "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line $1, column $2|-$3"; }

echo "--- 1. a member's FIRST/SKIP limits only its member (it cut the whole union)"
pin  "1 FIRST in the first member" "select first 2 a from t1 union all select x from t2;" "A|10|20|5|6|<null>|8|9|10"
pin  "1 ...under a trailing ORDER BY" "select first 2 a from t1 union all select x from t2 order by 1;" "A|<null>|5|6|8|9|10|10|20"
pin  "1 ...a distinct UNION" "select first 2 a from t1 union select x from t2;" "A|<null>|5|6|8|9|10|20"
pin  "1 ...distinct, ordered DESC" "select first 2 a from t1 union select x from t2 order by 1 desc;" "A|20|10|9|8|6|5|<null>"
pin  "1 ...UNION DISTINCT spelled out" "select first 2 a from t1 union distinct select x from t2;" "A|<null>|5|6|8|9|10|20"
pin  "1 FIRST+SKIP in two members" "select first 1 skip 1 a from t1 union all select first 2 x from t2;" "A|20|5|6"
pin  "1 ...both limited, then ordered" "select first 2 skip 1 a from t1 union all select first 1 skip 2 x from t2 order by 1;" "A|<null>|<null>|20"
pin  "1 FIRST 1 in each of three members" "select first 1 a from t1 union all select first 1 x from t2 union all select first 1 k from t3;" "A|10|5|1"
pin  "1 FIRST 0 empties only its member" "select first 0 a from t1 union all select x from t2;" "A|5|6|<null>|8|9|10"
pin  "1 FIRST beside the member's DISTINCT" "select first 2 distinct a from t1 union all select x from t2;" "A|<null>|10|5|6|<null>|8|9|10"
pin  "1 two columns" "select first 3 a, v from t1 union all select x, s from t2;" "A V|10 apple|20 banana|<null> cherry|5 one|6 two|<null> three|8 <null>|9 five|10 six"
pin  "1 members with their own WHERE" "select first 2 a from t1 where a is not null union all select x from t2 where x > 8;" "A|10|20|9|10"
pin  "1 as a derived table" "select * from (select first 2 a from t1 union all select x from t2) d;" "A|10|20|5|6|<null>|8|9|10"
pin  "1 ...counted" "select count(*) from (select first 2 a from t1 union all select x from t2) d;" "COUNT|8"
pin  "1 CONTROL SKIP in the first member agreed already" "select skip 5 a from t1 union all select x from t2 where id=1;" "A|20|5"
pin  "1 CONTROL FIRST in the second member" "select a from t1 union all select first 2 x from t2;" "A|10|20|<null>|10|30|20|5|6"
pin  "1 CONTROL SKIP in the second member" "select a from t1 union all select skip 4 x from t2;" "A|10|20|<null>|10|30|20|9|10"

echo "--- 2. the union's own ROWS/OFFSET/FETCH beside a member's FIRST"
pin  "2 member FIRST, union ROWS" "select first 2 a from t1 union all select x from t2 rows 3;" "A|10|20|5"
pin  "2 ...ordered" "select first 2 a from t1 union all select x from t2 order by 1 rows 3;" "A|<null>|5|6"
pin  "2 second member FIRST, union ROWS" "select a from t1 union all select first 2 x from t2 rows 3;" "A|10|20|<null>"
pin  "2 member FIRST, union OFFSET" "select first 2 a from t1 union all select x from t2 offset 1 rows;" "A|20|5|6|<null>|8|9|10"
pin  "2 member FIRST, union FETCH" "select first 2 a from t1 union all select x from t2 fetch first 3 rows only;" "A|10|20|5"
pin  "2 FIRST 1 in both, OFFSET 1 (it answered 2)" "select first 1 id from t1 union all select first 1 id from t2 offset 1 rows;" "ID|1"
pin  "2 member FIRST, union ROWS n TO m" "select first 2 a from t1 union all select x from t2 rows 2 to 4;" "A|20|5|6"
pin  "2 CONTROL a plain union's ROWS" "select a from t1 union all select x from t2 rows 3;" "A|10|20|<null>"
pin  "2 CONTROL a plain union's OFFSET/FETCH" "select a from t1 union all select x from t2 order by 1 offset 2 rows fetch next 3 rows only;" "A|5|6|8"

echo "--- 3. FIRST/SKIP and ROWS/OFFSET/FETCH on one query (the tail won)"
pin  "3 FIRST + ROWS" "select first 1 id from t1 order by id rows 3;" "$FS"
pin  "3 FIRST + OFFSET" "select first 1 id from t1 order by id offset 2 rows;" "$FS"
pin  "3 SKIP + FETCH" "select skip 1 id from t1 order by id fetch first 2 rows only;" "$FS"
pin  "3 FIRST SKIP + ROWS n TO m" "select first 1 skip 1 id from t1 rows 1 to 2;" "$FS"
pin  "3 FIRST (1) + ROWS, no ORDER" "select first (1) id from t1 rows 1;" "$FS"
pin  "3 in a derived table" "select * from (select first 1 id from t1 rows 2);" "$FS"
pin  "3 in a scalar subquery" "select (select first 1 id from t2 order by id rows 1) from t1;" "$FS"
pin  "3 in an EXISTS" "select id from t1 where exists (select first 1 id from t2 rows 1);" "$FS"
pin  "3 a CTE's main query" "with c as (select id from t1) select first 1 id from c rows 2;" "$FS"
pin  "3 an INSERT's source refuses and inserts nothing" "insert into t3 select first 1 id, 'q' from t1 rows 1; select count(*) from t3; rollback;" "$FS|COUNT|2"
pin  "3 an unknown TABLE outranks it" "select first 1 id from nosuch rows 2;" 'Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-"NOSUCH"|-At line 1, column 24'
pin  "3 ...an unknown column does not" "select first 1 nosuchcol from t1 rows 2;" "$FS"
pin  "3 CONTROL DISTINCT + ROWS is fine" "select distinct id from t1 order by id rows 2;" "ID|1|2"
pin  "3 CONTROL FIRST alone" "select first 2 id from t1 order by id desc;" "ID|6|5"

echo "--- 4. the parser's Token unknown (it answered, or refused bare)"
pin  "4 ORDER BY before UNION" "select id from t1 order by v union select id from t2;" "$(tok 1 30 union)"
pin  "4 ...the token as written" "select id from t1 order by v UNION select id from t2;" "$(tok 1 30 UNION)"
pin  "4 ...before UNION ALL" "select id from t1 order by v union all select id from t2;" "$(tok 1 30 union)"
pin  "4 ...on its own line" "select id from t1
order by v
union select id from t2;" "$(tok 3 1 union)"
pin  "4 ROWS in a member" "select id from t1 rows 2 union select id from t2;" "$(tok 1 26 union)"
pin  "4 OFFSET in a member" "select id from t1 offset 1 rows union select id from t2;" "$(tok 1 33 union)"
pin  "4 FETCH in a member" "select id from t1 fetch first 1 row only union select id from t2;" "$(tok 1 42 union)"
pin  "4 ORDER BY in a middle member" "select id from t1 union all select id from t2 order by 1 union all select 3 from t3;" "$(tok 1 58 union)"
pin  "4 ORDER BY ROWS in a middle member" "select id from t1 union select id from t2 order by 1 rows 2 union select 7 from t3;" "$(tok 1 61 union)"
pin  "4 FIRST + ROWS in a member: the parse error first" "select first 1 id from t1 rows 2 union select id from t2;" "$(tok 1 34 union)"
pin  "4 ...an unknown table: the parse error first" "select id from nosuch order by id union select id from t2;" "$(tok 1 35 union)"
pin  "4 a comment is not a token" "select id from t1 /* c */ order by v union select id from t2;" "$(tok 1 38 union)"
pin  "4 a 'union' literal is not one either" "select id, 'union' from t1 order by v union select id, 'x' from t2;" "$(tok 1 39 union)"
pin  "4 the column counts BYTES" "select 'ăîș' v from t1 order by v union select s from t2;" "$(tok 1 38 union)"
pin  "4 ROWS then OFFSET" "select id from t1 order by id rows 3 offset 1 rows;" "$(tok 1 38 offset)"
pin  "4 ROWS then FETCH" "select id from t1 rows 1 fetch first 1 row only;" "$(tok 1 26 fetch)"
pin  "4 OFFSET then ROWS" "select id from t1 order by id offset 1 rows rows 2;" "$(tok 1 45 rows)"
pin  "4 FETCH then ROWS" "select id from t1 order by id fetch first 1 row only rows 2;" "$(tok 1 54 rows)"
pin  "4 FETCH then OFFSET" "select id from t1 order by id fetch first 1 row only offset 1 rows;" "$(tok 1 54 offset)"
pin  "4 ROWS n TO m then OFFSET" "select id from t1 order by id rows 2 to 3 offset 1 rows;" "$(tok 1 43 offset)"
pin  "4 FETCH twice" "select id from t1 order by id fetch next 1 rows only fetch next 1 rows only;" "$(tok 1 54 fetch)"
pin  "4 OFFSET twice" "select id from t1 order by id offset 1 rows offset 1 rows;" "$(tok 1 45 offset)"
pin  "4 ROWS twice" "select id from t1 order by id rows 1 rows 1;" "$(tok 1 38 rows)"
pin  "4 ROWS after WITH LOCK" "select first 1 id from t1 with lock rows 1;" "$(tok 1 37 rows)"
pin  "4 ...after the union's ROWS, a UNION" "select id from t1 union select id from t2 order by 1 rows 1 union select id from t3;" "$(tok 1 61 union)"
pin  "4 CONTROL OFFSET then FETCH" "select id from t1 order by id offset 1 row fetch next 2 rows only;" "ID|2|3"
pin  "4 CONTROL GROUP BY in a member" "select a from t1 group by a union select x from t2 group by x;" "A|<null>|5|6|8|9|10|20|30"
pin  "4 CONTROL a window's ORDER BY is not the member's" "select id, row_number() over (order by id desc) from t1 where id < 3 union all select 9, 9 from t3 where k = 1 order by 1;" "ID ROW_NUMBER|1 2|2 1|9 9"

echo "--- 5. recorded, not fixed: shapes this server refuses where the engine answers"
refused "5 a CTE whose main query is a UNION" "with c as (select id from t1) select first 1 id from c union all select id from t2;"
refused "5 ...with the union's own ROWS" "with c as (select id from t1) select id from c union all select id from t2 rows 3;"
refused "5 a PLAN clause in a member" "select id from t1 plan (t1 natural) union select id from t2;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-unionlimit-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 72 ]; then echo "FAIL only $ran checks ran (floor 72)"; fail=1; fi
exit $fail
