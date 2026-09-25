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
# The second round (sections 6-13), each measured on 2182:
#
#   * a limited member's EXPRESSION column is nameless, like an unlimited
#     one's: `select first 1 a + 1 from t1 union all ...` was named ADD.
#   * the limit grammar holds inside DML: an INSERT's source, and every
#     bracketed query of an UPDATE / DELETE / MERGE. `insert .. order by
#     id union all ..` inserted twelve rows where the engine refuses.
#   * the tail is one ordered sequence `[ORDER BY] [ROWS|OFFSET/FETCH]
#     [FOR UPDATE] [WITH LOCK] [OPTIMIZE FOR]`; FOR UPDATE / WITH LOCK /
#     OPTIMIZE belong to the SELECT statement only (a derived table's is
#     the unknown `for`). `for update rows 1` answered all six rows.
#   * an unknown FROM item outranks FIRST/SKIP-with-ROWS only when the
#     engine resolves it first - its spec's FROM, or an outer FROM ahead
#     of it; one in a WHERE / select-list subquery loses to the -104. A
#     comma-joined unknown table (`from t1, nosuch`) is the -204.
#   * FIRST over an aggregate / GROUP BY plans (a member's and alone).
#   * a union value that does not fit the union's column at its scale is
#     22003 (it was relabelled: the INT128 max came back as
#     1701411834604692317316873037158841057.27).
#   * a correlated EXISTS with its own ROWS / OFFSET answers (it failed
#     its first row once FIRST beside ROWS refused), and ROWS before WITH
#     LOCK locks (it was refused as not a single table).
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
create table tn (id integer, bi bigint, i128 int128, n92 numeric(9,2), n184 numeric(18,4), n382 numeric(38,2));
insert into tn values (1, 9223372036854775807, 170141183460469231731687303715884105727, 1234567.89, 12345678901234.5678, 123456789012345678901234567890123456.78);
insert into tn values (2, -9223372036854775808, -170141183460469231731687303715884105728, -0.01, -0.0001, -0.01);
insert into tn values (3, null, null, null, null, null);
insert into tn values (4, 0, 0, 0, 0, 0);
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
# the engine and this server BOTH pinned where they differ and this round
# leaves it so - recorded with what each answers, never faked
differs() { # <label> <script> <engine-output> <this-server-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" = "$ev" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server moved: [$fv], recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server [${fv:0:60}])"; fi
}
FS='Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-FIRST/SKIP cannot be used with OFFSET/FETCH or ROWS'
TU() { echo "Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-\"$1\"|-At line $2, column $3"; }
OOR='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
WL() { echo "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-WITH LOCK $1"; }
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

echo "--- 6. a limited member's expression column is nameless (it was ADD, UPPER, ..)"
pin  "6 FIRST over a + 1" "select first 1 a + 1 from t1 union all select x * 2 from t2;" "11|10|12|<null>|16|18|20"
pin  "6 SKIP 0 over a + 1" "select skip 0 a + 1 from t1 union all select x * 2 from t2 where id < 3;" "11|21|<null>|11|31|21|10|12"
pin  "6 FIRST over UPPER, ordered" "select first 2 upper(v) from t1 union all select lower(s) from t2 order by 1;" "<null>|APPLE|BANANA|five|one|six|three|two"
pin  "6 ...a distinct union with its ROWS" "select first 2 a + 1 from t1 union select x from t2 order by 1 rows 2;" "<null>|5"
pin  "6 FIRST over COALESCE" "select first 1 coalesce(a, 0) from t1 union all select x from t2 where id = 1;" "10|5"
pin  "6 FIRST over CASE" "select first 1 case when a > 1 then 1 else 0 end from t1 union all select x from t2 where id = 1;" "1|5"
pin  "6 FIRST over a division" "select first 1 a / 2 from t1 union all select x from t2 where id = 1;" "5|5"
pin  "6 a member DISTINCT is the member's, and nameless" "select distinct a + 1 from t1 union all select x from t2;" "<null>|11|21|31|5|6|<null>|8|9|10"
pin  "6 FIRST over NULL takes the next member's type" "select first 1 null from t1 union all select first 1 x from t2;" "<null>|5"
pin  "6 CONTROL an aliased expression keeps its alias" "select first 1 a + 1 as q from t1 union all select x + 1 from t2;" "Q|11|6|7|<null>|9|10|11"
pin  "6 CONTROL a limited plain column keeps its name" "select first 1 a from t1 union all select x + 1 from t2;" "A|10|6|7|<null>|9|10|11"

echo "--- 7. the limit grammar inside DML (it ran, and changed rows)"
pin  "7 INSERT source: ORDER BY before UNION" "insert into t3 select id, 'q' from t1 order by id union all select id, 'r' from t2; select count(*) from t3; rollback;" "$(tok 1 51 union)|COUNT|2"
pin  "7 INSERT source: ROWS before UNION" "insert into t3 select id, 'q' from t1 rows 1 union all select id, 'r' from t2; select count(*) from t3; rollback;" "$(tok 1 46 union)|COUNT|2"
pin  "7 INSERT with a column list" "insert into t3 (k, name) select id, 'q' from t1 order by id union all select id, 'r' from t2; select count(*) from t3; rollback;" "$(tok 1 61 union)|COUNT|2"
pin  "7 INSERT source: a doubled ROWS" "insert into t3 select id, 'q' from t1 rows 1 rows 1; rollback;" "$(tok 1 46 rows)"
pin  "7 INSERT source: FOR UPDATE is not its" "insert into t3 select id, 'q' from t1 for update; rollback;" "$(tok 1 39 for)"
pin  "7 INSERT source: nor WITH LOCK" "insert into t3 select id, 'q' from t1 with lock; rollback;" "$(tok 1 39 with)"
pin  "7 DELETE's IN-subquery: ORDER BY before UNION" "delete from t3 where k in (select id from t1 order by id union all select id from t2); select count(*) from t3; rollback;" "$(tok 1 58 union)|COUNT|2"
pin  "7 UPDATE's IN-subquery: ROWS before UNION" "update t3 set k = 5 where k in (select id from t1 rows 1 union all select id from t2); select k from t3 order by k; rollback;" "$(tok 1 58 union)|K|1|2"
pin  "7 UPDATE's scalar subquery" "update t3 set k = (select id from t1 order by id union all select 1 from t2) where k = 1; rollback;" "$(tok 1 50 union)"
pin  "7 DELETE's IN-subquery: FOR UPDATE" "delete from t3 where k in (select id from t1 for update); rollback;" "$(tok 1 46 for)"
pin  "7 MERGE's source" "merge into t3 using (select id from t1 order by id union select id from t2) s on t3.k = s.id when matched then update set name = 'm'; rollback;" "$(tok 1 52 union)"
pin  "7 UPDATE's scalar subquery: FIRST + ROWS" "update t3 set k = (select first 1 id from t1 order by id rows 1) where k = 1; rollback;" "$FS"
pin  "7 INSERT source: FIRST + ROWS after an unknown table is the -204" "insert into t3 select first 1 id, 'q' from nosuch rows 1; rollback;" "$(TU NOSUCH 1 44)"
pin  "7 CONTROL an INSERT source's own ORDER BY / ROWS" "insert into t3 select id, 'q' from t1 order by id rows 2; select count(*) from t3; rollback;" "COUNT|4"
pin  "7 CONTROL ...and ROWS then RETURNING" "insert into t3 select id, 'q' from t1 order by id rows 1 returning k; rollback;" "K|1"
pin  "7 CONTROL a union source" "insert into t3 select id, 'q' from t1 union all select id, 'r' from t2 order by 1 rows 1; select count(*) from t3; rollback;" "COUNT|3"

echo "--- 8. FOR UPDATE, WITH LOCK, OPTIMIZE: one ordered tail, the statement's own"
pin  "8 WITH LOCK before UNION" "select id from t1 with lock union select id from t2;" "$(tok 1 29 union)"
pin  "8 FOR UPDATE before UNION" "select id from t1 for update union select id from t2;" "$(tok 1 30 union)"
pin  "8 FOR UPDATE OF before UNION" "select id from t1 for update of id union select id from t2;" "$(tok 1 36 union)"
pin  "8 OPTIMIZE before UNION" "select id from t1 optimize for first rows union select id from t2;" "$(tok 1 43 union)"
pin  "8 ROWS after FOR UPDATE (it answered six rows)" "select id from t1 for update rows 1;" "$(tok 1 30 rows)"
pin  "8 ...after FOR UPDATE OF" "select id from t1 order by id for update of id rows 1;" "$(tok 1 48 rows)"
pin  "8 ...after a union's FOR UPDATE" "select id from t1 union all select id from t2 order by 1 for update rows 1;" "$(tok 1 69 rows)"
pin  "8 ROWS after SKIP LOCKED" "select id from t1 with lock skip locked rows 1;" "$(tok 1 41 rows)"
pin  "8 ROWS after OPTIMIZE" "select id from t1 optimize for first rows rows 1;" "$(tok 1 43 rows)"
pin  "8 ORDER BY after ROWS" "select id from t1 rows 1 order by id;" "$(tok 1 26 order)"
pin  "8 ORDER BY after OFFSET" "select id from t1 offset 1 rows order by id;" "$(tok 1 33 order)"
pin  "8 ORDER BY after FOR UPDATE" "select id from t1 for update order by id;" "$(tok 1 30 order)"
pin  "8 ORDER BY after WITH LOCK" "select id from t1 with lock order by id;" "$(tok 1 29 order)"
pin  "8 ORDER BY twice" "select id from t1 order by id order by id;" "$(tok 1 31 order)"
pin  "8 FOR UPDATE twice" "select id from t1 for update for update;" "$(tok 1 30 for)"
pin  "8 WITH LOCK twice" "select id from t1 with lock with lock;" "$(tok 1 29 with)"
pin  "8 FOR UPDATE after WITH LOCK" "select id from t1 with lock for update;" "$(tok 1 29 for)"
pin  "8 WITH LOCK after OPTIMIZE" "select id from t1 optimize for first rows with lock;" "$(tok 1 43 with)"
pin  "8 FOR UPDATE in a derived table" "select * from (select id from t1 for update) d;" "$(tok 1 34 for)"
pin  "8 WITH LOCK in a derived table" "select * from (select id from t1 with lock) d;" "$(tok 1 34 with)"
pin  "8 FOR UPDATE in a scalar subquery" "select (select first 1 id from t2 for update) from t1 rows 1;" "$(tok 1 35 for)"
pin  "8 WITH LOCK in an IN-subquery" "select id from t1 where id in (select id from t2 with lock);" "$(tok 1 50 with)"
pin  "8 OPTIMIZE in a derived table is an alias, then FOR" "select * from (select id from t1 optimize for first rows) d;" "$(tok 1 43 for)"
pin  "8 FOR UPDATE in a CTE body" "with c as (select id from t1 for update) select id from c;" "$(tok 1 30 for)"
pin  "8 ROWS before WITH LOCK locks (it was refused)" "select id from t1 rows 2 with lock;" "ID|1|2"
pin  "8 ...with SKIP LOCKED" "select id from t1 rows 1 with lock skip locked;" "ID|1"
pin  "8 ...a union's ROWS" "select id from t1 union all select id from t2 rows 3 with lock;" "ID|1|2|3"
pin  "8 ...FOR UPDATE OF between" "select id from t1 rows 1 for update of id with lock;" "ID|1"
pin  "8 ...an aggregate's own message" "select count(*) from t1 rows 1 with lock;" "$(WL 'cannot be used with aggregates')"
pin  "8 ...DISTINCT's own message" "select distinct id from t1 rows 1 with lock;" "$(WL 'cannot be used with DISTINCT')"
pin  "8 CONTROL a join's message" "select a.id from t1 a join t2 b on a.id = b.id rows 1 with lock;" "$(WL 'can be used only with a single physical table')"
pin  "8 CONTROL a union's FOR UPDATE" "select id from t1 where id < 3 union select id from t2 where id < 3 for update;" "ID|1|2"
pin  "8 CONTROL FOR UPDATE then WITH LOCK" "select id from t1 where id < 3 for update of id with lock;" "ID|1|2"
pin  "8 CONTROL FOR UPDATE then OPTIMIZE" "select id from t1 where id < 3 for update optimize for all rows;" "ID|1|2"
pin  "8 CONTROL a union's ROWS then OPTIMIZE" "select id from t1 union select id from t2 rows 1 optimize for first rows;" "ID|1"
# the lint must not call a PSQL cursor's FOR UPDATE unknown: this server
# refuses the block (cursors), but bare - never with a made-up -104
differs "8 CONTROL a PSQL cursor's FOR UPDATE is its own" "set term ^;
execute block returns (r integer) as declare c cursor for (select id from t1 for update); begin open c; fetch c into :r; close c; suspend; end^
set term ;^" "R|1" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"

echo "--- 9. which comes first: an unknown table's -204 or FIRST/SKIP's -104"
pin  "9 a comma-joined unknown table (it was the -104)" "select first 1 id from t1, nosuch rows 1;" "$(TU NOSUCH 1 28)"
pin  "9 ...quoted, placed at its quote" "select first 1 id from t1 a, \"nosuch\" b rows 1;" "$(TU nosuch 1 30)"
pin  "9 an unknown table in the WHERE's subquery loses (it was the -204)" "select first 1 id from t1 where id in (select id from nosuch) rows 1;" "$FS"
pin  "9 ...and in the select list's" "select first 1 (select id from nosuch) from t1 rows 1;" "$FS"
pin  "9 a derived table's FIRST + ROWS before the unknown item" "select * from (select first 1 id from t1 rows 1) d, nosuch;" "$FS"
pin  "9 ...after it" "select * from nosuch, (select first 1 id from t1 rows 1) d;" "$(TU NOSUCH 1 15)"
pin  "9 an unknown item after a join" "select first 1 t1.id from t1 left join t2 on t1.id = t2.id, nosuch rows 1;" "$(TU NOSUCH 1 61)"
pin  "9 no FIRST: a comma-joined unknown table is the -204 (it refused bare)" "select id from t1, nosuch;" "$(TU NOSUCH 1 20)"
pin  "9 ...aliased" "select id from t1 a, nosuch b;" "$(TU NOSUCH 1 22)"
pin  "9 an AND resolves its RIGHT operand first on this engine build" "select * from t1 where id in (select first 1 id from t2 rows 1) and exists (select 1 from nosuch);" "$(TU NOSUCH 1 91)"
pin  "9 ...the same two the other way round" "select * from t1 where exists (select 1 from nosuch) and id in (select first 1 id from t2 rows 1);" "$FS"
pin  "9 ...three operands, OR" "select * from t1 where id in (select first 1 id from t2 rows 1) or id > 0 or exists (select 1 from nosuch);" "$(TU NOSUCH 1 100)"
pin  "9 ...a BETWEEN's AND is not an operand" "select * from t1 where id in (select first 1 id from t2 rows 1) and id between 1 and 3 and exists (select 1 from nosuch);" "$(TU NOSUCH 1 114)"
pin  "9 ...inside a bracketed group of operands too" "select * from t1 where (id in (select first 1 id from t2 rows 1) and exists (select 1 from nosuch));" "$(TU NOSUCH 1 92)"
pin  "9 ...and a group after an operand" "select * from t1 where exists (select 1 from nosuch) and (id > 0 or id in (select first 1 id from t2 rows 1));" "$FS"
pin  "9 the WHERE before the select list" "select (select first 1 id from t2 rows 1) from t1 where exists (select 1 from nosuch);" "$(TU NOSUCH 1 79)"
pin  "9 CONTROL a joined unknown table" "select first 1 t1.id from t1 join nosuch on 1 = 1 rows 1;" "$(TU NOSUCH 1 35)"

echo "--- 10. FIRST over an aggregate or a GROUP BY (refused once a member's FIRST stayed its own)"
pin  "10 FIRST over COUNT and SUM members" "select first 1 count(*) from t1 union all select first 1 sum(x) from t2;" "COUNT|6|38"
pin  "10 FIRST over a GROUP BY member" "select first 2 a, count(*) from t1 group by a union all select x, 1 from t2 where x > 8;" "A COUNT|<null> 1|10 2|9 1|10 1"
pin  "10 ...counted in a derived table" "select * from (select first 1 count(*) from t1 union all select sum(x) from t2) d(q);" "Q|6|38"
pin  "10 FIRST over a lone aggregate" "select first 1 count(*) from t1;" "COUNT|6"
pin  "10 FIRST over a GROUP BY" "select first 2 a, count(*) from t1 group by a;" "A COUNT|<null> 1|10 2"
pin  "10 FIRST SKIP over an ordered GROUP BY" "select first 2 skip 1 a, count(*) from t1 group by a order by 2 desc, 1;" "A COUNT|20 2|<null> 1"
pin  "10 FIRST DISTINCT over a GROUP BY" "select first 2 distinct a, count(*) from t1 group by a;" "A COUNT|<null> 1|10 2"
pin  "10 CONTROL a constant under FIRST" "select first 1 1 from rdb\$database;" "CONSTANT|1"

echo "--- 11. a q-string's quotes are its own (a made-up Token unknown)"
pin  "11 a real error after a q-string" "select q'{x}' from t1 order by 1 union select 'a' from t2;" "$(tok 1 34 union)"
pin  "11 ...a q-string holding a quote" "select q'{'}' from t1 order by 1 union select 'a' from t2;" "$(tok 1 34 union)"

echo "--- 12. a union value past its column at the union's scale is 22003 (it was relabelled)"
pin  "12 NUMERIC(38,2) beside NUMERIC(18,4)" "select n382 from tn union all select n184 from tn;" "N382|$OOR"
pin  "12 INT128 beside NUMERIC(38,2)" "select i128 from tn union all select n382 from tn;" "I128|$OOR"
pin  "12 rows ahead of the bad one arrive" "select n92 from tn union all select n184 from tn union all select n382 from tn;" "N92|1234567.8900|-0.0100|<null>|0.0000|12345678901234.5678|-0.0001|<null>|0.0000|$OOR"
pin  "12 ...the INT128 minimum" "select n382 from tn where id <> 1 union all select i128 from tn where id <> 1;" "N382|-0.01|<null>|0.00|$OOR"
pin  "12 BIGINT beside NUMERIC(18,4)" "select bi from tn union all select n184 from tn;" "BI|$OOR"
pin  "12 a sorted union raises before any row" "select n382 from tn union all select n184 from tn order by 1;" "N382|$OOR"
pin  "12 ...a distinct one" "select n92 from tn union select n382 from tn union select n184 from tn;" "N92|$OOR"
pin  "12 CONTROL BIGINT beside NUMERIC(38,2) fits" "select bi from tn union all select n382 from tn where id = 2;" "BI|9223372036854775807.00|-9223372036854775808.00|<null>|0.00|-0.01"
pin  "12 CONTROL NUMERIC(9,2) beside NUMERIC(18,4)" "select n92 from tn union all select n184 from tn where id = 1;" "N92|1234567.8900|-0.0100|<null>|0.0000|12345678901234.5678"

echo "--- 13. a subquery's own ROWS / OFFSET beside the query's FIRST"
pin  "13 a correlated EXISTS with ROWS (it failed its first row)" "select id from t1 where exists (select 1 from t2 where t2.id = t1.id rows 1) order by id;" "ID|1|2|3|4|5|6"
pin  "13 ...with OFFSET, under FIRST" "select first 2 id from t1 where exists (select 1 from t2 where t2.id = t1.id offset 0 rows) order by id;" "ID|1|2"
pin  "13 an IN-subquery's ROWS under FIRST" "select first 2 id from t1 where id in (select id from t2 rows 3) order by id;" "ID|1|2"

echo "--- 14. recorded, not fixed (second round)"
refused "14 a window under a member's FIRST (the fold's row order is not the window's)" "select first 3 row_number() over (order by id desc) from t1 union all select first 1 x from t2;"
refused "14 ...under FIRST alone" "select first 3 row_number() over (order by id desc) from t1;"
refused "14 a union ORDER BY of two keys (with or without FIRST)" "select first 1 id, a from t1 union all select first 1 id, x from t2 order by 1, 2 desc;"
refused "14 a quantified comparison over a union" "select 1 from rdb\$database where 20 = any (select first 2 a from t1 union all select x from t2);"
refused "14 a q-string (this server has none)" "select q'{'}', ' order ', ' union ' from t1 rows 1;"
refused "14 an UPDATE's own ORDER BY / ROWS" "update t3 set name = 'z' order by k rows 1; select name from t3 order by k; rollback;"
differs "14 COUNT(*) over a union whose value overflows its column" "select count(*) from (select n382 from tn union all select n184 from tn);" "COUNT|$OOR" "COUNT|8"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-unionlimit-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 181 ]; then echo "FAIL only $ran checks ran (floor 181)"; fail=1; fi
exit $fail
