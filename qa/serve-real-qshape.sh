#!/bin/bash
# QUERY SHAPES THE ENGINE ANSWERS AND THIS SERVER REFUSED - a JOIN's
# USING list, a qualified star, a CTE's scope, a subquery predicate or a
# predicate used as a VALUE, LATERAL spelled as a join, a parenthesised
# FROM, a UNION's ORDER BY list and mixed chain, a mixed IN list. Every
# cell measured on engine LI-T6.0.0.2182 and PINNED (rows, or the whole
# error vector; `dpin` the describe - type, nullability, name, alias):
#
#   1. `JOIN .. USING (<cols>)` is a NATURAL join over the named columns:
#      the derived equality, the merged column shown ONCE at the left
#      side's place by `*` (`T3 A JOIN T3 B USING (NAME)` is K, NAME, K),
#      its bare name the pair's COALESCE over a RIGHT / FULL join. A
#      column the left sides lack is the -206 `<left side of USING>."X"`,
#      one the joined side lacks `<right side of USING>."X"` (left first,
#      at the column's position), a column twice the -104 "appears more
#      than once in USING clause" - column by column, in list order.
#   2. Two UNALIASED mentions of one table (`T1 NATURAL JOIN T1`, `T1
#      JOIN T1 ON 1=1`) answer while nothing qualifies by the name.
#   3. A QUALIFIED STAR beside other items or over a join is that FROM
#      item's columns in declared order - a merged side whole under its
#      own qualifier, a derived table's output names.
#   4. A CTE is in scope in EVERY query of its statement - a scalar or IN
#      subquery, a UNION member, a later CTE's union; a WITH opening a
#      derived table or subquery answers alone, and nested under another
#      WITH is the -104 "WITH clause can't be nested".
#   5. `<literal> [NOT] IN (<subquery>)` over NO ROWS is FALSE / TRUE.
#   6. `[NOT] IN / <op> ALL | ANY | SOME (<subquery>)` as a VALUE is
#      TWO-VALUED: FALSE, never NULL, for a NULL left side or a set whose
#      NULL leaves the verdict unknown (a literal IN list stays three-
#      valued); over no rows IN / ANY are FALSE and NOT IN / ALL TRUE.
#      A set of UNICODE_CI texts compares under UNICODE_CI (`V IN (SELECT
#      S FROM CI)` finds 'apple' by 'APPLE'); a GROUP BY key naming such
#      an item covers nothing - alone it is the -104 "Invalid expression
#      in the select list", beside the item's column it answers.
#   7. A parenthesised predicate is a BOOLEAN operand - `(P) IS [NOT]
#      TRUE / FALSE / UNKNOWN`, `B = (P)`, `COALESCE(P, FALSE)` - and a
#      COALESCE / NULLIF / IIF / CASE whose value is BOOLEAN is a search
#      condition (a non-boolean one the 22000 "Invalid usage of boolean
#      expression").
#   8. `CROSS JOIN LATERAL` and `[INNER] JOIN LATERAL .. ON TRUE` are the
#      comma form's rows.
#   9. A whole FROM in parentheses is its join.
#  10. A UNION's ORDER BY takes several ORDINALS (a name, an alias, an
#      expression or an ordinal past the last column is the -104 "invalid
#      ORDER BY clause"); a chain mixing UNION and UNION ALL groups from
#      the LEFT; a parenthesised member is its query.
#  11. An IN list is ONE type (InListBoolNode::dsqlPass): text and number
#      literals together are TEXT, so `V IN (1, 'apple')` finds the row
#      where comparing item by item raised 22018 on 'banana'.
#
# Section 12 RECORDS what stays refused (or answers with another error),
# each cell checked to still refuse. `CONTROL` cells agreed before this
# gate; every other cell was red on master db71a0e.
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5830}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/qshape-eng.fdb"; FC="$D/qshape-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
create table t1 (id integer not null primary key, a integer, b bigint, n numeric(10,2), v varchar(20), d date, f double precision, bo boolean);
create table t2 (id integer not null primary key, t1id integer, x integer, s varchar(20));
create table t3 (k integer, name varchar(10));
create table e (id integer);
insert into t1 values (1, 10, 100, 1.50, 'apple', date '2020-01-01', 1.5, true);
insert into t1 values (2, 20, null, 2.25, 'banana', date '2021-06-15', null, false);
insert into t1 values (3, null, 300, null, 'cherry', null, 3.25, null);
insert into t1 values (4, 10, 400, -4.00, null, date '2019-12-31', -1.0, true);
insert into t1 values (5, 30, 500, 5.55, 'a_b%c', date '2022-02-28', 2.0, false);
insert into t1 values (6, 20, 600, 0.00, 'Apple', date '2020-01-01', 0.0, true);
insert into t2 values (1, 1, 5, 'one');
insert into t2 values (2, 1, 6, 'two');
insert into t2 values (3, 2, null, 'three');
insert into t2 values (4, 7, 8, null);
insert into t2 values (5, null, 9, 'five');
insert into t2 values (6, 4, 10, 'six');
insert into t3 values (1, 'x');
insert into t3 values (2, 'y');
insert into t3 values (null, 'z');
insert into t3 values (1, 'x2');
create table b (id int, bo boolean, i int);
insert into b values (1,true,1);
insert into b values (2,false,null);
insert into b values (3,null,3);
create table ci (id integer, s varchar(10) character set utf8 collate unicode_ci);
create table cai (id integer, s varchar(10) character set utf8 collate unicode_ci_ai);
create table u8 (id integer, s varchar(10) character set utf8);
insert into ci values (1, 'APPLE');
insert into ci values (2, 'Straße');
insert into cai values (1, 'ÁPPLE');
insert into cai values (2, 'b');
insert into u8 values (1, 'apple');
insert into u8 values (2, 'STRASSE');
insert into u8 values (3, 'straße');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/qshape-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/qshape-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/qshape-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-qshape-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the describe: the sqltype lines and the name / alias lines
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -a 'sqltype\|: name:' | sed 's/^ *//;s/  */ /g' | paste -sd'|'; }
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
dpin() { # <label> <script> <engine-describe>
    ran=$((ran + 1))
    local ev fv
    ev=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fv=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE DESCRIBES [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (describe)"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
refused() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" != "$ev" ]; then echo "FAIL $1 - the engine raises [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS [$ev]; promote the cell"; fail=1
    elif [ "${fv#Statement failed}" = "$fv" ]; then echo "FAIL $1 - answers WRONG: eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 (recorded: engine answers [${ev:0:60}], this server refuses)"; fi
}
differs() { # <label> <script> <engine-output> <this-server-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" = "$ev" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server moved: [$fv], recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server [${fv:0:60}])"; fi
}


echo "--- 1. JOIN ... USING is a NATURAL join over the named columns (every form refused)"
pin  "1 USING (ID), the merged bare name" "select id from t1 join t2 using (id) order by id;" "ID|1|2|3|4|5|6"
pin  "1 ...beside a plain column" "select id, a from t1 join t2 using (id) order by id;" "ID A|1 10|2 20|3 <null>|4 10|5 30|6 20"
pin  "1 ...the star shows the merged column once, at the left side's place" "select * from t1 join t2 using (id) order by 1;" "ID A B N V D F BO T1ID X S|1 10 100 1.50 apple 2020-01-01 1.500000000000000 <true> 1 5 one|2 20 <null> 2.25 banana 2021-06-15 <null> <false> 1 6 two|3 <null> 300 <null> cherry <null> 3.250000000000000 <null> 2 <null> three|4 10 400 -4.00 <null> 2019-12-31 -1.000000000000000 <true> 7 8 <null>|5 30 500 5.55 a_b%c 2022-02-28 2.000000000000000 <false> <null> 9 five|6 20 600 0.00 Apple 2020-01-01 0.000000000000000 <true> 4 10 six"
pin  "1 ...K NAME K: the star over a self join USING (NAME)" "select * from t3 a join t3 b using (name) order by 2;" "K NAME K|1 x 1|1 x2 1|2 y 2|<null> z <null>"
pin  "1 two columns" "select a.id from t1 a join t1 b using (id, a) order by 1;" "ID|1|2|4|5|6"
pin  "1 spaces inside the list" "select k from t3 a join t3 b using ( k ) order by 1;" "K|1|1|1|1|2"
pin  "1 INNER JOIN ... USING" "select k from t3 a inner join t3 b using (k) order by 1;" "K|1|1|1|1|2"
pin  "1 LEFT OUTER JOIN ... USING keeps the unmatched row" "select k from t3 a left outer join t3 b using (k) order by 1;" "K|<null>|1|1|1|1|2"
pin  "1 ...its star" "select * from t3 a left join t3 b using (k) order by 1, 2, 3;" "K NAME NAME|<null> z <null>|1 x x|1 x x2|1 x2 x|1 x2 x2|2 y y"
pin  "1 RIGHT JOIN ... USING, the merged name" "select id from t1 right join t2 using (id) order by 1;" "ID|1|2|3|4|5|6"
pin  "1 FULL JOIN ... USING: the bare name is the pair's COALESCE" "select k, a.k, b.k from t3 a full join (select 5 k, 'q' n from rdb\$database) b using (k) order by 1;" "K K K|<null> <null> <null>|1 1 <null>|1 1 <null>|2 2 <null>|5 <null> 5"
pin  "1 ...the star shows the coalesced value" "select * from t3 a full join (select 5 k, 'q' n from rdb\$database) b using (k) order by 1;" "K NAME N|<null> z <null>|1 x <null>|1 x2 <null>|2 y <null>|5 <null> q"
pin  "1 RIGHT JOIN over a derived side, the merged name" "select k from t3 a right join (select 5 k from rdb\$database) b using (k) order by 1;" "K|5"
pin  "1 qualified sides stay reachable" "select t1.id, t2.id, id from t1 join t2 using (id) order by 1;" "ID ID ID|1 1 1|2 2 2|3 3 3|4 4 4|5 5 5|6 6 6"
pin  "1 a USING step then an ON step" "select id from t1 join t2 using (id) join t3 on t3.k = t1.id order by 1;" "ID|1|1|2"
pin  "1 WHERE and ORDER BY on the merged name (inner)" "select a.id from t1 a join t2 b using (id) where id > 3 order by id;" "ID|4|5|6"
pin  "1 GROUP BY the merged name" "select id, count(*) from t1 join t2 using (id) group by id order by 1;" "ID COUNT|1 1|2 1|3 1|4 1|5 1|6 1"
pin  "1 a column the left side lacks: the -206 <left side of USING>" "select * from t1 join t2 using (s);" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-<left side of USING>.\"S\"|-At line 1, column 33"
pin  "1 ...aliased sides, its position" "select * from t1 a join t2 b using (x);" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-<left side of USING>.\"X\"|-At line 1, column 37"
pin  "1 a column the right side lacks: <right side of USING>" "select * from t1 join t2 using (a);" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-<right side of USING>.\"A\"|-At line 1, column 33"
pin  "1 ...over a LEFT JOIN" "select id from t2 left join t3 using (id);" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-<right side of USING>.\"ID\"|-At line 1, column 39"
pin  "1 a column twice: the -104" "select * from t1 join t2 using (id, id);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-column ID appears more than once in USING clause"
pin  "1 ...twice and unknown: the -206 at the first" "select * from t1 a join t2 b using (x, x);" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-<left side of USING>.\"X\"|-At line 1, column 37"

echo "--- 2. two UNALIASED mentions of one table answer while nothing qualifies by the name"
pin  "2 T1 NATURAL JOIN T1" "select id from t1 natural join t1 order by 1;" "ID|1|5|6"
pin  "2 ...its star" "select * from t1 natural join t1 order by 1;" "ID A B N V D F BO|1 10 100 1.50 apple 2020-01-01 1.500000000000000 <true>|5 30 500 5.55 a_b%c 2022-02-28 2.000000000000000 <false>|6 20 600 0.00 Apple 2020-01-01 0.000000000000000 <true>"
pin  "2 T1 JOIN T1 USING (ID)" "select id from t1 join t1 using (id) order by 1;" "ID|1|2|3|4|5|6"
pin  "2 T1 JOIN T1 ON 1=1" "select count(*) from t1 join t1 on 1=1;" "COUNT|36"
pin  "2 FROM T1, T1" "select count(*) from t1, t1;" "COUNT|36"

echo "--- 3. a qualified star beside other items or over a join is that item's columns"
pin  "3 T2.* over a join" "select t2.* from t1 join t2 on t2.t1id = t1.id where t1.id = 2;" "ID T1ID X S|3 2 <null> three"
pin  "3 an alias's star over a self join" "select a.* from t3 a join t3 b on a.k = b.k where b.name = 'y';" "K NAME|2 y"
pin  "3 two stars over a comma join" "select a.*, b.* from t3 a, t3 b where a.name = 'y' and b.name = 'z';" "K NAME K NAME|2 y <null> z"
pin  "3 a derived table's star" "select dt.* from (select id from t1) dt, t3 where t3.name = 'y' order by 1;" "ID|1|2|3|4|5|6"
pin  "3 a column then a star, ORDER BY a position inside the star" "select t1.id, t2.* from t1 join t2 on t2.t1id = t1.id order by 2;" "ID ID T1ID X S|1 1 1 5 one|1 2 1 6 two|2 3 2 <null> three|4 6 4 10 six"
pin  "3 ...a later position, DESC" "select t1.id, t2.* from t1 join t2 on t2.t1id = t1.id order by 5 desc;" "ID ID T1ID X S|1 2 1 6 two|2 3 2 <null> three|4 6 4 10 six|1 1 1 5 one"
pin  "3 two stars in reverse order" "select t2.*, t1.* from t1 join t2 on t2.t1id = t1.id where t1.id = 4;" "ID T1ID X S ID A B N V D F BO|6 4 10 six 4 10 400 -4.00 <null> 2019-12-31 -1.000000000000000 <true>"
pin  "3 the schema-qualified star" "select public.t2.* from t1 join t2 on t2.t1id = t1.id where t1.id = 4;" "ID T1ID X S|6 4 10 six"
pin  "3 an unaliased table's star beside an aliased one" "select t2.* from t1 a join t2 on t2.t1id = a.id where a.id = 4;" "ID T1ID X S|6 4 10 six"
pin  "3 a merged side is whole under its own qualifier" "select b.* from t3 a join t3 b using (k) where b.name = 'y';" "K NAME|2 y"
pin  "3 ...beside the other side's column" "select b.*, a.name from t3 a join t3 b using (k) where b.name = 'y';" "K NAME NAME|2 y y"
pin  "3 a derived table's aliased expression column" "select d.* from t3, (select k * 2 kk, name from t3) d where t3.k = 2 and d.kk = 4;" "KK NAME|4 y"
pin  "3 ...an UNNAMED one is the derived table's -104" "select d.* from t3, (select k * 2, name from t3) d where t3.k = 2;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-no column name specified for column number 1 in derived table D"
pin  "3 one table: a star then a column" "select t3.*, t3.k from t3 order by 2;" "K NAME K|1 x 1|1 x2 1|2 y 2|<null> z <null>"
pin  "3 under GROUP BY" "select a.*, count(*) from t3 a join t3 b on a.k = b.k group by a.k, a.name;" "K NAME COUNT|1 x 2|1 x2 2|2 y 1"
pin  "3 under DISTINCT" "select distinct a.* from t3 a join t3 b on a.k = b.k order by 1;" "K NAME|1 x|1 x2|2 y"
pin  "3 under FIRST" "select first 1 t2.* from t1 join t2 on t2.t1id = t1.id order by t2.id;" "ID T1ID X S|1 1 5 one"
pin  "3 beside a correlated scalar subquery" "select t1.*, (select count(*) from t2 where t2.t1id = t1.id) c from t1 order by 1;" "ID A B N V D F BO C|1 10 100 1.50 apple 2020-01-01 1.500000000000000 <true> 2|2 20 <null> 2.25 banana 2021-06-15 <null> <false> 1|3 <null> 300 <null> cherry <null> 3.250000000000000 <null> 0|4 10 400 -4.00 <null> 2019-12-31 -1.000000000000000 <true> 1|5 30 500 5.55 a_b%c 2022-02-28 2.000000000000000 <false> 0|6 20 600 0.00 Apple 2020-01-01 0.000000000000000 <true> 0"
pin  "3 beside a window" "select t1.*, row_number() over (order by id desc) rn from t1 order by 1;" "ID A B N V D F BO RN|1 10 100 1.50 apple 2020-01-01 1.500000000000000 <true> 6|2 20 <null> 2.25 banana 2021-06-15 <null> <false> 5|3 <null> 300 <null> cherry <null> 3.250000000000000 <null> 4|4 10 400 -4.00 <null> 2019-12-31 -1.000000000000000 <true> 3|5 30 500 5.55 a_b%c 2022-02-28 2.000000000000000 <false> 2|6 20 600 0.00 Apple 2020-01-01 0.000000000000000 <true> 1"
pin  "3 one table: a star then an expression" "select t3.*, t3.k + 1 from t3 where k = 2;" "K NAME ADD|2 y 3"
pin  "3 under FIRST / SKIP, one table" "select first 2 skip 1 t3.*, 1 from t3 order by 1, 2;" "K NAME CONSTANT|1 x 1|1 x2 1"
pin  "3 over a LEFT JOIN, the padded star" "select t1.id, t2.* from t1 left join t2 on t2.t1id = t1.id order by 1, 2;" "ID ID T1ID X S|1 1 1 5 one|1 2 1 6 two|2 3 2 <null> three|3 <null> <null> <null> <null>|4 6 4 10 six|5 <null> <null> <null> <null>|6 <null> <null> <null> <null>"
pin  "3 two derived tables' stars" "select x.*, y.* from (select 1 a from rdb\$database) x, (select 2 b from rdb\$database) y;" "A B|1 2"
pin  "3 inside a correlated EXISTS" "select id from t1 where exists (select t2.*, 1 from t2 where t2.t1id = t1.id) order by 1;" "ID|1|2|4"
pin  "3 a derived WITH's star over a join" "select c.*, t3.k from (with q as (select id from t1 where id < 3) select id from q) c join t3 on t3.k = c.id order by 1, 2;" "ID K|1 1|1 1|2 2"
pin  "3 inside a derived table, counted" "select count(*) from (select t1.*, t2.id i2 from t1 join t2 on t2.t1id = t1.id);" "COUNT|4"
pin  "3 CONTROL a qualifier nothing binds is the -206" "select x.* from t1 join t2 on t2.t1id = t1.id;" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-\"X\".*|-At line 1, column 8"
pin  "3 CONTROL an aliased table's own name is no qualifier" "select t1.* from t1 a join t2 on t2.t1id = a.id;" "Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-\"T1\".*|-At line 1, column 8"
pin  "3 CONTROL a lone star over one table" "select t3.* from t3 order by 1, 2;" "K NAME|<null> z|1 x|1 x2|2 y"

echo "--- 4. a CTE is in scope in every query of its statement"
pin  "4 a scalar subquery reads it" "with c as (select id from t1) select (select count(*) from c) from rdb\$database;" "COUNT|6"
pin  "4 a UNION member reads it" "with c as (select id from t1 where id < 3) select id from c union all select id from t2 where id = 1;" "ID|1|2|1"
pin  "4 an IN subquery reads it" "with c as (select id from t1) select id from t2 where id in (select id from c where id > 4) order by 1;" "ID|5|6"
pin  "4 a CTE whose body is a UNION over an earlier one" "with c as (select id from t1), d as (select id from c union all select id from c) select count(*) from d;" "COUNT|12"
pin  "4 a WITH inside a derived table" "select * from (with c as (select id from t1 where id = 2) select * from c);" "ID|2"
pin  "4 ...beside another derived table" "select * from (select id from t1 where id = 1) a, (with c as (select 5 z from rdb\$database) select z from c) b;" "ID Z|1 5"
pin  "4 an EXISTS reads it, correlated" "with c as (select t1id from t2) select id from t1 where exists (select 1 from c where c.t1id = t1.id) order by 1;" "ID|1|2|4"
pin  "4 a renaming column list, read in a subquery" "with c (q) as (select id from t1) select (select max(q) from c) from rdb\$database;" "MAX|6"
pin  "4 a WITH nested under a WITH is the -104 \"can't be nested\"" "with c as (select 1 v from rdb\$database) select * from (with c as (select 2 v from rdb\$database) select v from c);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-WITH clause can't be nested"
pin  "4 ...a WITH in a CTE body too" "with c as (select * from (with d as (select 1 v from rdb\$database) select v from d)) select * from c;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-WITH clause can't be nested"
pin  "4 ...a WITH inside a derived WITH" "select * from (with c as (select * from (with d as (select 1 v from rdb\$database) select v from d)) select v from c);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-WITH clause can't be nested"
pin  "4 a WITH in an IN subquery" "select id from t1 where id in (with c as (select t1id from t2) select t1id from c) order by 1;" "ID|1|2|4"
pin  "4 a WITH in a scalar subquery" "select (with c as (select id from t1) select count(*) from c) from rdb\$database;" "COUNT|6"
pin  "4 a derived WITH over a join" "select d.id, t3.name from (with c as (select id from t1 where id < 3) select id from c) d join t3 on t3.k = d.id order by 1, 2;" "ID NAME|1 x|1 x2|2 y"
pin  "4 CONTROL a CTE used twice in one FROM" "with c as (select id from t1 where id < 3) select a.id, b.id from c a join c b on a.id = b.id order by 1;" "ID ID|1 1|2 2"

echo "--- 5. <literal> [NOT] IN (<subquery>) over no rows"
pin  "5 1 NOT IN (empty) is TRUE" "select 3 from rdb\$database where 1 not in (select id from e);" "CONSTANT|3"
pin  "5 1 IN (empty) is FALSE" "select 2 from rdb\$database where 1 in (select id from e);" ""
pin  "5 NULL NOT IN (empty) is TRUE" "select 4 from rdb\$database where null not in (select id from e);" "CONSTANT|4"
pin  "5 beside a conjunct" "select 5 from t1 where 1 not in (select id from e) and id = 1;" "CONSTANT|5"
pin  "5 a text literal" "select 6 from t1 where id = 1 and 'a' in (select cast(id as varchar(5)) from e);" ""
pin  "5 CONTROL a column left side" "select count(*) from t1 where a not in (select id from e);" "COUNT|6"
pin  "5 CONTROL a non-empty set" "select 7 from rdb\$database where 7 not in (select id from t2);" "CONSTANT|7"

echo "--- 6. [NOT] IN / ALL / ANY (subquery) as a VALUE is two-valued"
pin  "6 IIF over IN" "select id, iif(id in (select t1id from t2), 1, 0) r from t1 order by 1;" "ID R|1 1|2 1|3 0|4 1|5 0|6 0"
pin  "6 > ALL over no rows is TRUE" "select id, a > all (select k from t3 where k > 5) r from t1 order by 1;" "ID R|1 <true>|2 <true>|3 <true>|4 <true>|5 <true>|6 <true>"
pin  "6 IN over a one-row set" "select id, a in (select x from t2 where id = 1) r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <false>|4 <false>|5 <false>|6 <false>"
pin  "6 CASE WHEN IN" "select id, case when a in (select k from t3) then 'y' else 'n' end r from t1 order by 1;" "ID R|1 n|2 n|3 n|4 n|5 n|6 n"
pin  "6 NOT IN over a set holding NULL is FALSE for every row" "select id, a not in (select x from t2) from t1 order by 1;" "ID BOOL|1 <false>|2 <false>|3 <false>|4 <false>|5 <false>|6 <false>"
pin  "6 > ALL over a set holding NULL" "select id, a > all (select k from t3) from t1 order by 1;" "ID BOOL|1 <false>|2 <false>|3 <false>|4 <false>|5 <false>|6 <false>"
pin  "6 four at once: NULL and no-match are FALSE" "select id, a, a in (select x from t2) r1, a not in (select x from t2) r2, a in (select x from t2 where x is not null) r3, a not in (select x from t2 where x is not null) r4 from t1 order by 1;" "ID A R1 R2 R3 R4|1 10 <true> <false> <true> <false>|2 20 <false> <false> <false> <true>|3 <null> <false> <false> <false> <false>|4 10 <true> <false> <true> <false>|5 30 <false> <false> <false> <true>|6 20 <false> <false> <false> <true>"
pin  "6 = ANY, > ALL, < ANY, > SOME" "select id, a, a = any (select k from t3) r1, a > all (select k from t3) r2, a > all (select k from t3 where k is not null) r3, a < any (select k from t3) r4, a > some (select k from t3 where k is not null) r5 from t1 order by 1;" "ID A R1 R2 R3 R4 R5|1 10 <false> <false> <true> <false> <true>|2 20 <false> <false> <true> <false> <true>|3 <null> <false> <false> <false> <false> <false>|4 10 <false> <false> <true> <false> <true>|5 30 <false> <false> <true> <false> <true>|6 20 <false> <false> <true> <false> <true>"
pin  "6 every quantifier over no rows" "select id, a in (select id from e) r1, a not in (select id from e) r2, a > all (select id from e) r3, a = any (select id from e) r4 from t1 order by 1;" "ID R1 R2 R3 R4|1 <false> <true> <true> <false>|2 <false> <true> <true> <false>|3 <false> <true> <true> <false>|4 <false> <true> <true> <false>|5 <false> <true> <true> <false>|6 <false> <true> <true> <false>"
pin  "6 CASE with IN then NOT IN" "select id, case when a in (select x from t2) then 'y' when a not in (select x from t2) then 'n' else 'u' end r from t1 order by 1;" "ID R|1 y|2 u|3 u|4 y|5 u|6 u"
pin  "6 an unaliased item is named BOOL" "select a in (select x from t2) from t1 where id = 1;" "BOOL|<true>"
pin  "6 an expression on both sides" "select id, a + 1 in (select x + 1 from t2) r, id from t1 order by 1;" "ID R ID|1 <true> 1|2 <false> 2|3 <false> 3|4 <true> 4|5 <false> 5|6 <false> 6"
pin  "6 IIF over >= ALL" "select id, iif(a >= all (select a from t1 where a is not null), 'max', 'no') r from t1 order by 1;" "ID R|1 no|2 no|3 no|4 no|5 max|6 no"
pin  "6 text IN" "select id, v in (select s from t2) r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <false>|4 <false>|5 <false>|6 <false>"
pin  "6 IN AND a boolean column" "select id, a in (select x from t2) and bo r from t1 order by 1;" "ID R|1 <true>|2 <false>|3 <false>|4 <true>|5 <false>|6 <false>"
pin  "6 IN OR a boolean column" "select id, a in (select x from t2) or bo r from t1 order by 1;" "ID R|1 <true>|2 <false>|3 <null>|4 <true>|5 <false>|6 <true>"
pin  "6 compared with a boolean column" "select id, (a in (select x from t2)) = bo r from t1 order by 1;" "ID R|1 <true>|2 <true>|3 <null>|4 <true>|5 <true>|6 <false>"
pin  "6 CONTROL a literal IN list stays three-valued" "select id, a in (10, null) r1, a not in (10, null) r2 from t1 order by 1;" "ID R1 R2|1 <true> <false>|2 <null> <null>|3 <null> <null>|4 <true> <false>|5 <null> <null>|6 <null> <null>"
pin  "6 CONTROL WHERE NOT (IN) drops the unknown rows" "select id from t1 where not (a in (select x from t2)) order by 1;" ""
pin  "6 a UNICODE_CI set compares case-blind: IN" "select id, v in (select s from ci) from t1 order by 1;" "ID BOOL|1 <true>|2 <false>|3 <false>|4 <false>|5 <false>|6 <true>"
pin  "6 ...a literal left side" "select id, 'apple' in (select s from ci) r from t1 where id < 3 order by 1;" "ID R|1 <true>|2 <true>"
pin  "6 ...NOT IN" "select id, v not in (select s from ci) r from t1 order by 1;" "ID R|1 <false>|2 <true>|3 <true>|4 <false>|5 <true>|6 <false>"
pin  "6 ...= ANY and <> ALL" "select id, v = any (select s from ci) r1, v <> all (select s from ci) r2 from t1 order by 1;" "ID R1 R2|1 <true> <false>|2 <false> <true>|3 <false> <true>|4 <false> <false>|5 <false> <true>|6 <true> <false>"
pin  "6 ...a one-row set" "select id, v in (select s from ci where id = 1) r from t1 order by 1;" "ID R|1 <true>|2 <false>|3 <false>|4 <false>|5 <false>|6 <true>"
pin  "6 ...under IIF" "select id, iif(v in (select s from ci), 'y', 'n') r from t1 order by 1;" "ID R|1 y|2 n|3 n|4 n|5 n|6 y"
pin  "6 ...> ANY" "select id, v > any (select s from ci) r from t1 order by 1;" "ID R|1 <false>|2 <true>|3 <true>|4 <false>|5 <false>|6 <false>"
pin  "6 ...a plain UTF8 column left" "select id, s in (select s from ci) r from u8 order by 1;" "ID R|1 <true>|2 <false>|3 <true>"
pin  "6 ...an UPPER over the CI column keeps it" "select id, s in (select upper(s) from ci) r from u8 order by 1;" "ID R|1 <true>|2 <false>|3 <true>"
pin  "6 ...the CI column left, a plain UTF8 set" "select id, s in (select s from u8) r from ci order by 1;" "ID R|1 <true>|2 <true>"
pin  "6 CONTROL a COLLATE UNICODE set is case-bound" "select id, v in (select s collate unicode from ci) r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <false>|4 <false>|5 <false>|6 <false>"
pin  "6 GROUP BY the ordinal of an IN item alone: the -104" "select a in (select x from t2), count(*) from t1 group by 1;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)"
pin  "6 ...of a > ALL item" "select a > all (select x from t2 where x is not null), count(*) from t1 group by 1;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)"
pin  "6 ...by its alias" "select a in (select x from t2) as bb, count(*) from t1 group by bb;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)"
pin  "6 ...over an empty set" "select a in (select id from e), count(*) from t1 group by 1;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)"
pin  "6 ...beside the item's column it answers" "select a in (select x from t2) bb, count(*) from t1 group by a, bb;" "BB COUNT|<false> 1|<true> 2|<false> 2|<false> 1"
pin  "6 ...the ordinal after the column" "select a, count(*), a in (select x from t2) from t1 group by 3, 1 order by 1;" "A COUNT BOOL|<null> 1 <false>|10 2 <true>|20 2 <false>|30 1 <false>"
pin  "6 CONTROL a constant left side groups by 1" "select 1 in (select id from e), count(*) from t1 group by 1;" "BOOL COUNT|<false> 6"
pin  "6 CONTROL GROUP BY the column under the item" "select a, a in (select x from t2), count(*) from t1 group by a order by 1;" "A BOOL COUNT|<null> <false> 1|10 <true> 2|20 <false> 2|30 <false> 1"
pin  "6 an item folded to a constant is still described BOOL: over no rows" "set sqlda_display on; select 1 not in (select id from e) from rdb\$database;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 32764 BOOLEAN Nullable scale: 0 subtype: 0 len: 1|: name: BOOL alias: BOOL|: table: schema: owner:|BOOL|<true>"
pin  "6 ...> ALL over a set holding NULL, aliased" "set sqlda_display on; select a > all (select x from t2) r from t1 where 1=0;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 32764 BOOLEAN Nullable scale: 0 subtype: 0 len: 1|: name: BOOL alias: R|: table: schema: owner:"
dpin "6 the describe of a projected IN" "select a in (select x from t2) from t1 where id = 1;" "01: sqltype: 32764 BOOLEAN Nullable scale: 0 subtype: 0 len: 1"

echo "--- 7. a predicate is a BOOLEAN value: IS TRUE / UNKNOWN, compared, a COALESCE / IIF / CASE of one as a search condition"
pin  "7 (pred) IS TRUE" "select id, (a > 15) is true r from t1 order by 1;" "ID R|1 <false>|2 <true>|3 <false>|4 <false>|5 <true>|6 <true>"
pin  "7 (pred) IS NOT TRUE" "select id, (a > 15) is not true r from t1 order by 1;" "ID R|1 <true>|2 <false>|3 <true>|4 <true>|5 <false>|6 <false>"
pin  "7 (pred) IS UNKNOWN" "select id, (a > 15) is unknown r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <true>|4 <false>|5 <false>|6 <false>"
pin  "7 (pred) IS NOT UNKNOWN" "select id, (a > 15) is not unknown r from t1 order by 1;" "ID R|1 <true>|2 <true>|3 <false>|4 <true>|5 <true>|6 <true>"
pin  "7 (pred) IS FALSE" "select id, (a > 15) is false r from t1 order by 1;" "ID R|1 <true>|2 <false>|3 <false>|4 <true>|5 <false>|6 <false>"
pin  "7 bool = (pred)" "select id, bo = (a > 15) r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <null>|4 <false>|5 <false>|6 <true>"
pin  "7 (pred) = bool" "select id, (a > 15) = bo r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <null>|4 <false>|5 <false>|6 <true>"
pin  "7 (pred) <> (pred)" "select id, (a > 15) <> (b > 300) r from t1 order by 1;" "ID R|1 <false>|2 <null>|3 <null>|4 <true>|5 <false>|6 <false>"
pin  "7 COALESCE(bool, FALSE) AND pred" "select id, coalesce(bo, false) and a > 10 r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <false>|4 <false>|5 <false>|6 <true>"
pin  "7 CASE WHEN COALESCE(bool, ..)" "select id, case when coalesce(bo, false) then 'y' else 'n' end r from t1 order by 1;" "ID R|1 y|2 n|3 n|4 y|5 n|6 y"
pin  "7 COALESCE over a predicate, inside IIF" "select id, iif(coalesce(a > 15, false), 1, 0) r from t1 order by 1;" "ID R|1 0|2 1|3 0|4 0|5 1|6 1"
pin  "7 COALESCE over a literal IN list" "select id, coalesce(a in (10, null), false) r from t1 order by 1;" "ID R|1 <true>|2 <false>|3 <false>|4 <true>|5 <false>|6 <false>"
pin  "7 WHERE COALESCE(bool, FALSE)" "select id from t1 where coalesce(bo, false) order by 1;" "ID|1|4|6"
pin  "7 WHERE IIF(..)" "select id from t1 where iif(a > 15, true, false) order by 1;" "ID|2|5|6"
pin  "7 WHERE CASE .. END" "select id from t1 where case when a > 15 then true else false end order by 1;" "ID|2|5|6"
pin  "7 WHERE NOT COALESCE(..)" "select id from t1 where not coalesce(bo, false) order by 1;" "ID|2|3|5"
pin  "7 WHERE COALESCE(..) AND .." "select id from t1 where coalesce(bo, false) and a > 10 order by 1;" "ID|6"
pin  "7 WHERE (COALESCE(..))" "select id from t1 where (coalesce(bo, false)) order by 1;" "ID|1|4|6"
pin  "7 WHERE NULLIF(bool, FALSE)" "select id from t1 where nullif(bo, false) order by 1;" "ID|1|4|6"
pin  "7 WHERE COALESCE over an INTEGER is the 22000" "select id from t1 where coalesce(a, 0) order by 1;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 WHERE (pred) IS TRUE" "select id from t1 where (a > 15) is true order by 1;" "ID|2|5|6"
pin  "7 WHERE (pred) IS UNKNOWN" "select id from t1 where (a > 15) is unknown order by 1;" "ID|3"
pin  "7 WHERE (pred) IS NOT TRUE" "select id from t1 where (a > 15) is not true order by 1;" "ID|1|3|4"
pin  "7 WHERE (pred) IS FALSE AND bool" "select id from t1 where (a > 15) is false and bo order by 1;" "ID|1|4"
pin  "7 WHERE NOT ((pred) IS TRUE)" "select id from t1 where not ((a > 15) is true) order by 1;" "ID|1|3|4"
pin  "7 WHERE bool = (pred)" "select id from t1 where bo = (a > 15) order by 1;" "ID|6"
pin  "7 ...over a join" "select t1.id from t1 join t2 on t2.t1id = t1.id where (t1.a > 15) is true order by 1;" "ID|2"
pin  "7 WHERE (col) IS TRUE over an INTEGER is the 22000" "select id from t1 where (a) is true order by 1;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 CONTROL (expr) * 2 = n is arithmetic, not a boolean group" "select id from t1 where (coalesce(a, 0)) * 2 = 20 order by 1;" "ID|1|4"
pin  "7 CONTROL (a + 8) * 2" "select id from t1 where (a + 8) * 2 = 36 order by 1;" "ID|1|4"
pin  "7 CONTROL (pred) = TRUE" "select id from t1 where (a = 10) = true order by 1;" "ID|1|4"
pin  "7 CONTROL (pred) OR (pred)" "select id from t1 where (a = 10) or (b = 300) order by 1;" "ID|1|3|4"
pin  "7 CONTROL a nested group" "select id from t1 where ((a = 10) or b = 300) and id > 1 order by 1;" "ID|3|4"
pin  "7 CONTROL (col) = n" "select id from t1 where (a) = 10 order by 1;" "ID|1|4"
pin  "7 CONTROL (bool)" "select id from t1 where (bo) order by 1;" "ID|1|4|6"
pin  "7 CONTROL pred AND bool as a value" "select id, (a > 15) and bo r from t1 order by 1;" "ID R|1 <false>|2 <false>|3 <null>|4 <false>|5 <false>|6 <true>"
dpin "7 the describe of (pred) IS TRUE" "select (a > 15) is true from t1 where id = 1;" "01: sqltype: 32764 BOOLEAN Nullable scale: 0 subtype: 0 len: 1"

echo "--- 8. LATERAL spelled as a join"
pin  "8 CROSS JOIN LATERAL" "select t1.id, l.m from t1 cross join lateral (select max(x) m from t2 where t2.t1id = t1.id) l order by 1;" "ID M|1 6|2 <null>|3 <null>|4 10|5 <null>|6 <null>"
pin  "8 JOIN LATERAL .. ON TRUE" "select t1.id, l.m from t1 join lateral (select max(x) m from t2 where t2.t1id = t1.id) l on true order by 1;" "ID M|1 6|2 <null>|3 <null>|4 10|5 <null>|6 <null>"
pin  "8 INNER JOIN LATERAL drops an empty subquery's row" "select t1.id, l.x from t1 inner join lateral (select x from t2 where t2.t1id = t1.id) l on true order by 1, 2;" "ID X|1 5|1 6|2 <null>|4 10"
pin  "8 CROSS JOIN LATERAL, a multi-row subquery" "select t1.id, l.x from t1 cross join lateral (select x from t2 where t2.t1id = t1.id) l order by 1, 2;" "ID X|1 5|1 6|2 <null>|4 10"
pin  "8 CONTROL the comma form" "select t1.id, l.x from t1, lateral (select x from t2 where t2.t1id = t1.id) l order by 1, 2;" "ID X|1 5|1 6|2 <null>|4 10"
pin  "8 CONTROL LEFT JOIN LATERAL .. ON TRUE" "select t1.id, l.x from t1 left join lateral (select x from t2 where t2.t1id = t1.id) l on true order by 1, 2;" "ID X|1 5|1 6|2 <null>|3 <null>|4 10|5 <null>|6 <null>"

echo "--- 9. a whole FROM in parentheses"
pin  "9 (T1 JOIN T2 ON ..)" "select t1.id, t2.id from (t1 join t2 on t2.t1id = t1.id) order by 1,2;" "ID ID|1 1|1 2|2 3|4 6"
pin  "9 ...counted" "select count(*) from (t1 join t2 on t2.t1id = t1.id);" "COUNT|4"
pin  "9 a chain in parentheses" "select t1.id, t2.id, t3.k from (t1 join t2 on t2.t1id = t1.id join t3 on t3.k = t2.id) order by 1,2;" "ID ID K|1 1 1|1 1 1|1 2 2"
pin  "9 a LEFT JOIN in parentheses" "select t1.id, t2.id from (t1 left join t2 on t2.t1id = t1.id) order by 1,2;" "ID ID|1 1|1 2|2 3|3 <null>|4 6|5 <null>|6 <null>"
pin  "9 two pairs of parentheses" "select t1.id from ((t1 join t2 on t2.t1id = t1.id)) order by 1;" "ID|1|1|2|4"

echo "--- 10. UNION: an ORDER BY of several ordinals, a mixed chain, parenthesised members"
pin  "10 ORDER BY 1, 2" "select id, a from t1 union all select id, x from t2 order by 1, 2;" "ID A|1 5|1 10|2 6|2 20|3 <null>|3 <null>|4 8|4 10|5 9|5 30|6 10|6 20"
pin  "10 ORDER BY 2 DESC, 1" "select id, a from t1 union all select id, x from t2 order by 2 desc, 1;" "ID A|5 30|2 20|6 20|1 10|4 10|6 10|5 9|4 8|2 6|1 5|3 <null>|3 <null>"
pin  "10 ORDER BY 2 NULLS FIRST, 1 DESC over a distinct union" "select id, a from t1 union select id, x from t2 order by 2 nulls first, 1 desc;" "ID A|3 <null>|1 5|2 6|4 8|5 9|6 10|4 10|1 10|6 20|2 20|5 30"
pin  "10 a name is the -104 invalid ORDER BY clause" "select id, a from t1 union all select id, x from t2 order by a, id;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-invalid ORDER BY clause"
pin  "10 ...the first member's alias too" "select id as z from t1 union select id from t2 order by z;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-invalid ORDER BY clause"
pin  "10 ...a name, DESC" "select id from t1 union all select id from t2 order by id desc;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-invalid ORDER BY clause"
pin  "10 ...an expression" "select id from t1 union select id from t2 order by id+0;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-invalid ORDER BY clause"
pin  "10 ...an ordinal past the last column" "select id, a from t1 union all select id, x from t2 order by 3;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-invalid ORDER BY clause"
pin  "10 UNION then UNION ALL groups from the left" "select a from t1 union select x from t2 union all select k from t3 order by 1;" "A|<null>|<null>|1|1|2|5|6|8|9|10|20|30"
pin  "10 UNION ALL then UNION deduplicates all" "select a from t1 union all select x from t2 union select k from t3 order by 1;" "A|<null>|1|2|5|6|8|9|10|20|30"
pin  "10 four members, three operators" "select a from t1 union select x from t2 union all select k from t3 union select 99 from rdb\$database order by 1;" "A|<null>|1|2|5|6|8|9|10|20|30|99"
pin  "10 a mixed chain counted in a derived table" "select count(*) from (select a from t1 union select x from t2 union all select k from t3);" "COUNT|12"
pin  "10 a mixed chain's first member keeps its own FIRST" "select first 2 a from t1 union select x from t2 union all select k from t3;" "A|<null>|5|6|8|9|10|20|1|2|<null>|1"
pin  "10 ...UNION ALL first" "select first 2 a from t1 union all select x from t2 union select k from t3;" "A|<null>|1|2|5|6|8|9|10|20"
pin  "10 ...a FIRST in the middle member" "select a from t1 union select first 1 x from t2 union all select k from t3;" "A|<null>|5|10|20|30|1|2|<null>|1"
pin  "10 a mixed chain's ROWS is the whole chain's" "select a from t1 union select x from t2 union all select k from t3 rows 3;" "A|<null>|5|6"
pin  "10 a DISTINCT first member of a mixed chain" "select distinct a from t1 union all select x from t2 union select k from t3;" "A|<null>|1|2|5|6|8|9|10|20|30"
pin  "10 a CTE read by a mixed chain" "with c as (select a from t1) select a from c union select x from t2 union all select k from t3 order by 1;" "A|<null>|<null>|1|1|2|5|6|8|9|10|20|30"
pin  "10 parenthesised members, ordered" "(select id from t1 where id < 3) union all (select id from t2 where id > 4) order by 1;" "ID|1|2|5|6"
pin  "10 parenthesised members, distinct" "(select id from t1 where id < 3) union (select id from t2 where id > 4);" "ID|1|2|5|6"
pin  "10 the second member parenthesised" "select id from t1 where id = 1 union all (select id from t2 where id = 2);" "ID|1|2"
pin  "10 a member in two pairs of parentheses" "((select id from t1 where id = 1)) union all select 7 from rdb\$database;" "ID|1|7"
pin  "10 a member's own FIRST and ORDER BY inside its parentheses" "(select first 1 id from t1 order by id desc) union all (select first 1 id from t2 order by id) order by 1;" "ID|1|6"
pin  "10 CONTROL a union inside an IN subquery" "select id from t1 where id in (select id from t2 union select k from t3) order by 1;" "ID|1|2|3|4|5|6"
pin  "10 CONTROL one ordinal key" "select id from t1 union all select id from t2 order by 1 desc;" "ID|6|6|5|5|4|4|3|3|2|2|1|1"

echo "--- 11. an IN list is ONE type: text and number literals together are text"
pin  "11 V IN (1, 'apple')" "select id from t1 where v in (1, 'apple');" "ID|1"
pin  "11 ...the other order" "select id from t1 where v in ('apple', 1) order by 1;" "ID|1"
pin  "11 NOT IN" "select id from t1 where v not in (1, 'apple') order by 1;" "ID|2|3|5|6"
pin  "11 a decimal beside a text" "select id from t1 where v in (1.5, 'apple') order by 1;" "ID|1"
pin  "11 as a value" "select id, iif(v in (1, 'apple'), 1, 0) from t1 order by 1;" "ID CASE|1 1|2 0|3 0|4 0|5 0|6 0"
pin  "11 CONTROL numbers only still compare as numbers" "select id from t1 where v in (1, 2);" "ID|Statement failed, SQLSTATE = 22018|conversion error from string \"apple\""
pin  "11 CONTROL one number" "select id from t1 where v in (1);" "ID|Statement failed, SQLSTATE = 22018|conversion error from string \"apple\""
pin  "11 CONTROL an INTEGER against text and number" "select id from t1 where a in ('10', 20) order by 1;" "ID|1|2|4|6"
pin  "11 CONTROL a BIGINT" "select id from t1 where b in (100, '300') order by 1;" "ID|1|3"
pin  "11 CONTROL NUMERIC against text and number" "select id from t1 where n in ('1.5', 2) order by 1;" "ID|1"

echo "--- 12. recorded, not fixed: each still refuses (or raises another error) where the engine answers"
refused "12 a parenthesised join as ONE operand of a join" "select t1.id, t2.id, t3.k from t1 join (t2 join t3 on t3.k = t2.id) on t2.t1id = t1.id order by 1,2;"
refused "12 a CORRELATED IN as a value" "select id, a in (select t1id from t2 where t2.t1id = t1.id) r from t1 order by 1;"
refused "12 NOT (IN) as a value" "select id, not (a in (select x from t2)) r from t1 order by 1;"
refused "12 a merged name in WHERE over a FULL join" "select k from t3 a full join (select 5 k, 'q' n from rdb\$database) b using (k) where k > 1 order by 1;"
refused "12 an expression left side over an empty IN" "select 7 from rdb\$database where 1 + 1 in (select id from e);"
refused "12 a subquery in a WHERE function argument" "select id from b where coalesce((select i from b where id = 2), 0) < 7 order by 1;"
refused "12 a LIST() in a scalar subquery" "select (select list(s, ',') from t2 where id < 3) from rdb\$database;"
refused "12 HAVING > ALL" "select a from t1 group by a having count(*) > all (select 1 from rdb\$database) order by 1;"
refused "12 a correlated subquery in a grouped ORDER BY" "select a, count(*) from t1 group by a order by (select count(*) from t2 where t2.x = t1.a);"
refused "12 SINGULAR" "select id from t1 where singular (select * from t2 where t2.t1id = t1.id) order by 1;"
refused "12 two recursive members" "with recursive r (n) as (select 1 from rdb\$database union all select n+1 from r where n < 3 union all select n+10 from r where n < 3) select n from r order by 1;"
refused "12 an unbounded recursive CTE under FIRST" "with recursive r (n) as (select 1 from rdb\$database union all select n+1 from r) select first 5 n from r;"
refused "12 FIRST (expr)" "select first (1+1) id from t1 order by id;"
refused "12 ROWS 1.5" "select id from t1 order by id rows 1.5;"
refused "12 a number INTEGER CONTAINING" "select id from t1 where b containing 0 order by 1;"
differs "12 a column item beside a text in an IN list: the engine answers, this server raises 22018 per row" "select id from t1 where v in (a, 'apple') order by 1;" "ID|1" "ID|Statement failed, SQLSTATE = 22018|conversion error from string \"apple\""
refused "12 a text UNION a number" "select id from t1 union select 'x' from rdb\$database order by 1;"
refused "12 a derived table's WITH declaring an UNUSED CTE (the engine warns; its end-of-query pass is not folded)" "select * from (with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select * from c);"
refused "12 a parenthesised column" "select id, (a) r from t1 order by 1;"
differs "12 T1.ID over T1 NATURAL JOIN T1 is the engine's -204 ambiguity; this server's bare refusal" "select t1.id from t1 natural join t1 order by 1;" "Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table \"PUBLIC\".\"T1\" and table \"PUBLIC\".\"T1\"|-ID" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
differs "12 a BOOLEAN UNION a number is the engine's HY004; this server's bare refusal" "select bo from t1 union select 1 from rdb\$database;" "Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression UNION" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
pin "12 a star beside a column is the engine's -104 at the comma (the refusal diagnosis names it)" "select * , t3.k from t3;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 10|-,"
differs "12 a text-only IN list against an INTEGER: the engine's message pads the item to the list's CHAR(2)" "select id from t1 where a in ('10', 'x') order by 1;" "ID|Statement failed, SQLSTATE = 22018|conversion error from string \"x \"" "ID|Statement failed, SQLSTATE = 22018|conversion error from string \"x\""
refused "12 two ICU collations meet: a UNICODE_CI_AI column IN a UNICODE_CI set" "select id, s in (select s from ci) r from cai order by 1;"
refused "12 ...a UNICODE_CI column IN a UNICODE_CI_AI set" "select id, s in (select s from cai) r from ci order by 1;"
refused "12 ...a QUOTED name on the left side of a UNICODE_CI set (not typed)" "select id, \"V\" in (select s from ci) r from t1 order by 1;"
refused "12 ...a COLLATE on the left side" "select id, s collate unicode_ci_ai in (select s from ci) r from u8 order by 1;"
differs "12 GROUP BY the TEXT of a subquery-predicate item is the engine's -104; this server's bare refusal" "select a in (select x from t2) from t1 group by a in (select x from t2);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"
differs "12 a two-column IN subquery as a value is the engine's 07002; this server's bare refusal" "select id, a in (select x, id from t2) r from t1 order by 1;" "Statement failed, SQLSTATE = 07002|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-count of column list and variable list do not match" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-qshape-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 233 ]; then echo "FAIL only $ran checks ran (floor 233)"; fail=1; fi
exit $fail
