#!/bin/bash
# STATEMENT-LEVEL SEMANTIC CHECKS THE ENGINE RUNS AT PREPARE, and this
# server skipped - five laws, each answering rows where engine 2182
# refuses, measured vector by vector (SQLSTATE, message lines, position)
# and raised at the same phase (no column header: a prepare refusal):
#
#   1. A DERIVED TABLE's columns (PASS1_derived_table): the declared
#      column list's COUNT (54001 "has less/more columns"), an UNNAMED
#      column, a DUPLICATE name ("column ID was specified multiple times
#      for derived table DT") - in that order, an unnamed derived table
#      spelled `<unnamed>`. A CTE is a derived table by another name and
#      takes the same three checks under its own name. `SELECT * FROM
#      (SELECT ID, ID FROM T1)` answered twelve rows here.
#   2. An ALIAS CONFLICT (-204 "alias "C" conflicts with an alias in the
#      same statement"): two aliases at one query level - and an UNUSED
#      CTE, whose definition the engine passes at the end of the
#      statement under its own name, after posting one "CTE "C" is not
#      used in query" WARNING per unused CTE (in declaration order, one
#      `SQL warning code = -104` header). The warnings ride a successful
#      prepare too. `WITH C AS (..), C AS (..) SELECT * FROM C` answered
#      the first definition here; an unused CTE never warned.
#   3. A QUALIFIER NOTHING BINDS (-206 "Column unknown", the reference
#      quoted part by part, its line and column): the base name of an
#      ALIASED table above all (`FROM T1 T ... ORDER BY T1.ID` answered
#      six rows here), a wrong schema, a name no FROM item carries, a
#      known relation's missing column. The engine reports the FIRST
#      offender in its pass order - FROM (ON conditions, derived bodies),
#      WHERE, select list, ORDER BY, GROUP BY, HAVING; inside a boolean
#      the RIGHT operand of AND / OR first, a comparison's left side
#      first, an arithmetic's right operand first, `IN (SELECT ..)`'s
#      subquery before its left side, a select-list subquery after the
#      plain items - all measured and matched below.
#   4. A RECURSIVE CTE MEMBER (pass1RecursiveCte): a self-reference as a
#      side of an OUTER join ("Recursive member of CTE can't be member of
#      an outer join" - this answered five rows), a second reference, a
#      CROSS / NATURAL join side or a subquery reference ("can refer
#      itself only in FROM clause"), DISTINCT / GROUP BY / HAVING, an
#      aggregate or window function, a bare UNION link, a non-recursive
#      member after a recursive one, no anchor, no union - checked when
#      the CTE is ADDED, read by the main query or not.
#   5. WITH LOCK over a relation the request parser refuses (par.cpp,
#      SQLSTATE HY000, two lines): a system table, a virtual one (MON$,
#      SEC$), a global temporary table - after every DSQL WITH LOCK check
#      and every -206, and never for a UNION ALL chain, which the engine
#      locks. `SELECT 1 FROM RDB$DATABASE WITH LOCK` answered here.
#
# RECORDED, not fixed (every one a refusal on this server, never a wrong
# answer): a quoted CTE name; a CTE referenced only inside a subquery or
# a derived table; a nested WITH; a bare (unqualified) unknown column,
# whose -206 this server does not spell; the same reference in a CASE
# (the engine reads the THEN branch first); a UNION's ORDER BY and a
# plain column beside a HAVING (the engine's -104s); an EXECUTE BLOCK or
# a CREATE VIEW / PROCEDURE carrying any of the five (the engine's
# vector, sometimes under "unsuccessful metadata update"); a
# parenthesised join, `USING`, FIRST / ROWS or a subquery beside a
# recursive member, two recursive members, two recursive CTEs; a bare
# unknown column under WITH LOCK.
#
# Usage: qa/serve-real-semchk.sh [port]   (default 5950)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5950}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/semchk-eng.fdb"; FC="$D/semchk-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
create table t1 (id integer not null primary key, a integer, b bigint, n numeric(10,2), v varchar(20), d date, f double precision, bo boolean);
create table t2 (id integer not null primary key, t1id integer, x integer, s varchar(20));
create table t3 (k integer, name varchar(10));
create table e (id integer);
create global temporary table gtd (id integer) on commit delete rows;
create global temporary table gtp (id integer) on commit preserve rows;
create view sysv as select rdb$relation_id from rdb$database;
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
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/semchk-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/semchk-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/semchk-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-semchk-$PORT.log" 2>&1 & srv=$!
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
# so an error cell compares the engine's whole message, warnings included
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# an EXECUTE BLOCK / CREATE PROCEDURE script, terminators switched
eb() { printf 'SET TERM ^;\n%s^\nSET TERM ;^\n' "$1"; }
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
# the engine answers, this server REFUSES - recorded (never a wrong answer)
refused() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" != "$ev" ]; then echo "FAIL $1 - the engine raises now [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server refuses)"; fi
}
# BOTH RAISE, with different vectors - the engine's pinned by a substring,
# this server's must be a refusal that does not (yet) match; the day it
# does, the cell says so and is promoted to a pin
err_differs() { # <label> <script> <engine-substring>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*$3}" = "$ev" ]; then echo "FAIL $1 - the ENGINE vector moved: [$ev] no longer carries [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded vector gap: engine [${ev:0:70}])"; fi
}

I104='Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
R104='Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104'
C54='Statement failed, SQLSTATE = 54001|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
E206='Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown'
A204='Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-alias'
W104='SQL warning code = -104'
HY='Statement failed, SQLSTATE = HY000'
OJ="$R104|-Recursive member of CTE can't be member of an outer join"
DUP='was specified multiple times for derived table'
NU='no column name specified for column number'
LESS='has less columns than the number of items in its SELECT statement'
MORE='has more columns than the number of items in its SELECT statement'
NOTUSED='is not used in query'
CONF='conflicts with an alias in the same statement'
SYSDB='Cannot select system table "SYSTEM"."RDB$DATABASE" for update WITH LOCK'

# the fixture really loaded (a `same` over an empty pair passes for nothing)
pin  "0 the fixture" "SELECT COUNT(*) FROM T1;" "COUNT|6"

echo "--- 1. A DERIVED TABLE's COLUMNS: count, unnamed, duplicate - in that order"
pin  "1 the member: SELECT * FROM (SELECT ID, ID FROM T1)" "select * from (select id, id from t1);" "$I104|-column ID $DUP <unnamed>"
pin  "1 ...aliased DT" "select * from (select id, id from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 ...A AS ID" "select * from (select id, a as id from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 ...the outer never reads the pair" "select 1 from (select id, id from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 ...COUNT(*) over it" "select count(*) from (select id, id from t1);" "$I104|-column ID $DUP <unnamed>"
pin  "1 ...three of them" "select * from (select id, id, id from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 ...the pair apart (ID, A, ID)" "select * from (select id, a, id from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 ...ID AS \"ID\" is the same name" "select * from (select id, id as \"ID\" from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 ...a quoted lower-case pair reports it as carried" "select * from (select id as \"id\", id as \"id\" from t1) dt;" "$I104|-column id $DUP DT"
pin  "1 ...WHERE 0 = 1 changes nothing" "select * from (select id, id from t1) dt where 0 = 1;" "$I104|-column ID $DUP DT"
pin  "1 ...nested: the INNERMOST is named" "select * from (select * from (select id, id from t1) i) o;" "$I104|-column ID $DUP I"
pin  "1 ...as the right side of a LEFT JOIN" "select * from t2 left join (select id, id from t1) dt on 1 = 1;" "$I104|-column ID $DUP DT"
pin  "1 ...unnamed, as the left side of a JOIN" "select * from (select id, id from t1) join t2 on 1 = 1;" "$I104|-column ID $DUP <unnamed>"
pin  "1 ...inside an EXISTS" "select 1 from rdb\$database where exists (select * from (select id, id from t1) dt);" "$I104|-column ID $DUP DT"
pin  "1 ...inside an IN, correlated projection: at PREPARE, no header" "select * from t1 where id in (select t1.id from (select id, id from t1) x);" "$I104|-column ID $DUP X"
pin  "1 ...inside a scalar subquery" "select (select 1 from (select id, id from t1)) from rdb\$database;" "$I104|-column ID $DUP <unnamed>"
pin  "1 ...under ANY" "select 1 from rdb\$database where 1 = any (select id from (select 1 x, 1 x from rdb\$database));" "$I104|-column X $DUP <unnamed>"
pin  "1 ...with an ORDER BY" "select * from (select id, id from t1) dt order by 1;" "$I104|-column ID $DUP DT"
pin  "1 a UNION body names from its FIRST branch: A, A" "select * from (select a, a from t1 union all select id, id from t1) dt;" "$I104|-column A $DUP DT"
pin  "1 ...ID, ID first" "select * from (select id, id from t1 union all select id, a from t1) dt;" "$I104|-column ID $DUP DT"
pin  "1 CONTROL ...ID, A first answers" "select * from (select id, a from t1 union all select id, id from t1) dt;" "ID A|1 10|2 20|3 <null>|4 10|5 30|6 20|1 1|2 2|3 3|4 4|5 5|6 6"
pin  "1 unnamed BEFORE duplicate: 1 X, 1 X, 2 reports column 3" "select * from (select 1 x, 1 x, 2 from rdb\$database);" "$I104|-$NU 3 in derived table <unnamed>"
pin  "1 ...1, 1 X, 1 X reports column 1" "select * from (select 1, 1 x, 1 x from rdb\$database);" "$I104|-$NU 1 in derived table <unnamed>"
pin  "1 an unnamed derived table is spelled <unnamed> (this printed a blank)" "select * from (select 1 from rdb\$database);" "$I104|-$NU 1 in derived table <unnamed>"
pin  "1 ...1 X, 1 X" "select * from (select 1 x, 1 x from rdb\$database);" "$I104|-column X $DUP <unnamed>"
pin  "1 CONTROL ...renamed by a column list" "select * from (select 1 x, 1 x from rdb\$database) d (p, q);" "P Q|1 1"
pin  "1 the count FIRST: DT (X) over two items is 54001" "select * from (select id, a from t1) dt (x);" "$C54|-column list from derived table DT $LESS"
pin  "1 ...DT (X, Y, Z)" "select * from (select id, a from t1) dt (x, y, z);" "$C54|-column list from derived table DT $MORE"
pin  "1 ...DT (X, \"x\") over one item" "select * from (select id from t1) dt (x, \"x\");" "$C54|-column list from derived table DT $MORE"
pin  "1 ...the count beats the duplicate: (ID, ID) DT (X)" "select * from (select id, id from t1) dt (x);" "$C54|-column list from derived table DT $LESS"
pin  "1 ...(ID, A) DT (X, X, Y)" "select * from (select id, a from t1) dt (x, x, y);" "$C54|-column list from derived table DT $MORE"
pin  "1 a duplicate in the LIST: DT (X, X)" "select * from (select id, a from t1) dt (x, x);" "$I104|-column X $DUP DT"
pin  "1 ...quoted: DT (\"x\", \"x\")" "select * from (select id, a from t1) dt (\"x\", \"x\");" "$I104|-column x $DUP DT"
pin  "1 CONTROL DT (X, Y)" "select * from (select id, id from t1) dt (x, y);" "X Y|1 1|2 2|3 3|4 4|5 5|6 6"
pin  "1 ...BEFORE the lock check: (ID, ID) DT WITH LOCK" "select * from (select id, id from t1) dt with lock;" "$I104|-column ID $DUP DT"
pin  "1 ...(SELECT 1 ..) WITH LOCK" "select * from (select 1 from rdb\$database) with lock;" "$I104|-$NU 1 in derived table <unnamed>"
pin  "1 a CTE is a derived table: WITH C AS (SELECT ID, ID ..)" "with c as (select id, id from t1) select * from c;" "$I104|-column ID $DUP C"
pin  "1 ...SELECT C.ID FROM C" "with c as (select id, id from t1) select c.id from c;" "$I104|-column ID $DUP C"
pin  "1 ...COUNT(*) FROM C" "with c as (select id, id from t1) select count(*) from c;" "$I104|-column ID $DUP C"
pin  "1 ...C JOIN T2" "with c as (select id, id from t1) select * from c join t2 on 1 = 1;" "$I104|-column ID $DUP C"
pin  "1 ...unnamed in a CTE: (SELECT 1, 2 ..)" "with c as (select 1, 2 from rdb\$database) select * from c;" "$I104|-$NU 1 in derived table C"
pin  "1 ...(SELECT 1 X, 2 ..) reports column 2" "with c as (select 1 x, 2 from rdb\$database) select * from c;" "$I104|-$NU 2 in derived table C"
pin  "1 ...(SELECT COUNT(*) ..)" "with c as (select count(*) from t1) select * from c;" "$I104|-$NU 1 in derived table C"
pin  "1 ...C (A) over two items" "with c (a) as (select 1, 2 from rdb\$database) select * from c;" "$C54|-column list from derived table C $LESS"
pin  "1 ...C (A, B) over one" "with c (a, b) as (select 1 from rdb\$database) select * from c;" "$C54|-column list from derived table C $MORE"
pin  "1 ...C (A, A)" "with c (a, a) as (select 1, 2 from rdb\$database) select * from c;" "$I104|-column A $DUP C"
pin  "1 ...C (A) over a STAR body" "with c (a) as (select * from t1) select * from c;" "$C54|-column list from derived table C $LESS"
pin  "1 CONTROL ...C (eight names) over the star" "with c (a, b, n1, n2, v, d, f, bo) as (select * from t1) select a from c;" "A|1|2|3|4|5|6"
pin  "1 ...(1 X, 1 X) used" "with c as (select 1 x, 1 x from rdb\$database) select * from c;" "$I104|-column X $DUP C"
err_differs "1 RECORDED T1.*, T2.* over a join (a refusal here)" "select * from (select t1.*, t2.* from t1 join t2 on t2.t1id = t1.id) dt;" "column ID $DUP DT"
pin  "1 ...a scalar subquery over a derived table" "select (select first 1 x.id from (select id, id from t1) x) from rdb\$database;" "$I104|-column ID $DUP X"
err_differs "1 RECORDED LATERAL" "select * from t1 x, lateral (select x.id, x.id from rdb\$database) l;" "column ID $DUP L"
err_differs "1 RECORDED a quoted \"id\" is the engine's -206" "select * from (select id, \"id\" from t1) dt;" "Column unknown|-\"id\""
err_differs "1 RECORDED inside an EXECUTE BLOCK" "$(eb 'execute block returns (n integer) as begin select count(*) from (select id, id from t1) into n; suspend; end')" "column ID $DUP <unnamed>"
err_differs "1 RECORDED a CREATE VIEW over the pair is the catalog's 23000" "create view v1 as select id, id from t1;" "violation of PRIMARY or UNIQUE KEY constraint"
err_differs "1 RECORDED CREATE PROCEDURE" "$(eb 'create procedure psem returns (n integer) as begin select count(*) from (select id, id from t1) into n; suspend; end')" "column ID $DUP <unnamed>"
err_differs "1 RECORDED CREATE VIEW over an unnamed derived table" "create view vsem4 as select * from (select id, id from t1);" "column ID $DUP <unnamed>"

echo "--- 2. ALIAS CONFLICTS, and the UNUSED CTEs the engine passes last"
pin  "2 the member: WITH C, C SELECT * FROM C" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...c, C" "with c as (select 1 x from rdb\$database), C as (select 2 x from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...C, D, C warns D then C under ONE header" "with c as (select 1 x from rdb\$database), d as (select 2 x from rdb\$database), c as (select 3 x from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"D\" $NOTUSED|-CTE \"C\" $NOTUSED"
pin  "2 ...neither read: C, C" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select 1 from rdb\$database;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"C\" $NOTUSED"
pin  "2 ...C, D, C SELECT * FROM D" "with c as (select 1 x from rdb\$database), d as (select 2 x from rdb\$database), c as (select 3 x from rdb\$database) select * from d;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"C\" $NOTUSED"
pin  "2 ...different columns change nothing" "with c as (select 1 x from rdb\$database), c as (select 2 y from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...under WITH RECURSIVE" "with recursive c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...the second C in a bad column list: the alias conflicts first" "with c (a) as (select 1 from rdb\$database), c (b) as (select 2, 3 from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...the FIRST C in a bad column list: its count, no warning" "with c (a) as (select 1, 2 from rdb\$database), c as (select 3 from rdb\$database) select * from c;" "$C54|-column list from derived table C $LESS"
pin  "2 ...the first C duplicated: its pair, no warning" "with c as (select 1 x, 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c;" "$I104|-column X $DUP C"
pin  "2 ...the second C duplicated: the conflict, warned" "with c as (select 1 x from rdb\$database), c as (select 2 x, 2 x from rdb\$database) select * from c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 a reference aliased away conflicts with nothing: C C2 answers, warned" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c c2;" "$W104|-CTE \"C\" $NOTUSED|X|1"
pin  "2 ...C C1, C C2" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c c1, c c2;" "$W104|-CTE \"C\" $NOTUSED|X X|1 1"
pin  "2 a table aliased by a CTE's name: T1 C" "with c as (select 1 x from rdb\$database) select * from t1 c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...a derived table aliased C" "with c as (select 1 x from rdb\$database) select * from (select 1 y from rdb\$database) c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...a used CTE's name on a table: no unused pass, no conflict" "with c as (select 1 x from rdb\$database) select count(*) from c x, t1 c;" "COUNT|6"
pin  "2 ...C C1, C C2, T1 C" "with c as (select 1 x from rdb\$database) select count(*) from c c1, c c2, t1 c;" "COUNT|6"
pin  "2 ...C C (a reference under its own name)" "with c as (select 1 x from rdb\$database) select * from c c;" "X|1"
pin  "2 ...used only by an unused CTE is unused: C, D(C) .. T1 C" "with c as (select 1 x from rdb\$database), d as (select * from c) select * from t1 c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"D\" $NOTUSED"
pin  "2 ...C, D(C), E(D) .. T1 C" "with c as (select 1 x from rdb\$database), d as (select * from c), e as (select * from d) select * from t1 c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"D\" $NOTUSED|-CTE \"E\" $NOTUSED"
pin  "2 ...C, D SELECT * FROM C D" "with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select * from c d;" "$A204 \"D\" $CONF|$W104|-CTE \"D\" $NOTUSED"
pin  "2 ...C, D SELECT * FROM C, T1 D" "with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select * from c, t1 d;" "$A204 \"D\" $CONF|$W104|-CTE \"D\" $NOTUSED"
pin  "2 ...C, D(C) SELECT * FROM C, T1 D" "with c as (select 1 x from rdb\$database), d as (select * from c) select * from c, t1 d;" "$A204 \"D\" $CONF|$W104|-CTE \"D\" $NOTUSED"
err_differs "2 RECORDED C, D SELECT * FROM (SELECT * FROM C) D (a CTE inside a derived table refuses here)" "with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select * from (select * from c) d;" "alias \"D\" $CONF"
pin  "2 ...C, C .. T1 C" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from t1 c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"C\" $NOTUSED"
pin  "2 ...C, C, T1 .. FROM T1 (the CTE)" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database), t1 as (select 9 y from rdb\$database) select * from t1;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"C\" $NOTUSED"
pin  "2 ...C, C .. (SELECT 1 Y ..) C" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from (select 1 y from rdb\$database) c;" "$A204 \"C\" $CONF|$W104|-CTE \"C\" $NOTUSED|-CTE \"C\" $NOTUSED"
pin  "2 two references of one CTE at one level: C, C" "with c as (select 1 x from rdb\$database) select * from c, c;" "$A204 \"C\" $CONF"
pin  "2 ...C, T1 C" "with c as (select 1 x from rdb\$database) select * from c, t1 c;" "$A204 \"C\" $CONF"
pin  "2 ...C, (SELECT ..) C" "with c as (select 1 x from rdb\$database) select * from c, (select 2 y from rdb\$database) c;" "$A204 \"C\" $CONF"
pin  "2 ...C, C C" "with c as (select 1 x from rdb\$database) select * from c, c c;" "$A204 \"C\" $CONF"
pin  "2 ...two table aliases: T1 C, T2 C" "with c as (select 1 x from rdb\$database) select * from t1 c, t2 c;" "$A204 \"C\" $CONF"
pin  "2 ...two derived tables aliased D, no CTE at all" "select * from (select 1 x from rdb\$database) d, (select 2 y from rdb\$database) d;" "$A204 \"D\" $CONF"
pin  "2 ...C, C .. FROM C, T1 C (the main query's own conflict, no warning)" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c, t1 c;" "$A204 \"C\" $CONF"
pin  "2 an unused CTE's columns are checked: (1, 2) unnamed, warned" "with c as (select 1, 2 from rdb\$database), d as (select 3 y from rdb\$database) select * from d;" "$I104|-$NU 1 in derived table C|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...C (A) over two, warned" "with c (a) as (select 1, 2 from rdb\$database), d as (select 3 y from rdb\$database) select * from d;" "$C54|-column list from derived table C $LESS|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...C (A), D (B) both unused: C first" "with c (a) as (select 1 from rdb\$database), d (a) as (select 2, 3 from rdb\$database) select * from c;" "$C54|-column list from derived table D $LESS|$W104|-CTE \"D\" $NOTUSED"
pin  "2 ...(ID, ID) unused" "with c as (select id, id from t1), d as (select 1 y from rdb\$database) select * from d;" "$I104|-column ID $DUP C|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...(1, 2) alone" "with c as (select 1, 2 from rdb\$database) select 3 from rdb\$database;" "$I104|-$NU 1 in derived table C|$W104|-CTE \"C\" $NOTUSED"
pin  "2 ...(1 X, 1 X) alone" "with c as (select 1 x, 1 x from rdb\$database) select 1 from rdb\$database;" "$I104|-column X $DUP C|$W104|-CTE \"C\" $NOTUSED"
pin  "2 a SUCCESSFUL prepare carries the warning: WITH C .. SELECT 1" "with c as (select 1 x from rdb\$database) select 1 from rdb\$database;" "$W104|-CTE \"C\" $NOTUSED|CONSTANT|1"
pin  "2 ...C, D SELECT * FROM C warns D" "with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select * from c;" "$W104|-CTE \"D\" $NOTUSED|X|1"
pin  "2 ...C, D SELECT 1" "with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select 1 from rdb\$database;" "$W104|-CTE \"C\" $NOTUSED|-CTE \"D\" $NOTUSED|CONSTANT|1"
pin  "2 ...a qualified PUBLIC.T2 is the TABLE, and warns the CTE" "with t2 as (select 1 x from rdb\$database) select count(*) from public.t2;" "$W104|-CTE \"T2\" $NOTUSED|COUNT|6"
pin  "2 ...an unaliased table conflicts with nothing: T1 CTE shadows" "with t1 as (select 1 x from rdb\$database) select * from t1;" "X|1"
pin  "2 ...a subquery's alias is one level down: warned, answered" "with c as (select 1 x from rdb\$database) select count(*) from t1 where exists (select 1 from t2 c);" "$W104|-CTE \"C\" $NOTUSED|COUNT|6"
pin  "2 ...a CTE body's alias too: D AS (SELECT * FROM T1 C)" "with c as (select 1 x from rdb\$database), d as (select count(*) n from t1 c) select * from d;" "$W104|-CTE \"C\" $NOTUSED|N|6"
pin  "2 ...T1 C1, T1 C2 beside CTE C" "with c as (select 1 x from rdb\$database) select count(*) from t1 c1, t1 c2;" "$W104|-CTE \"C\" $NOTUSED|COUNT|36"
pin  "2 ...C, D SELECT X FROM C WHERE EXISTS (.. T1 D)" "with c as (select 1 x from rdb\$database), d as (select 2 y from rdb\$database) select x from c where exists (select 1 from t1 d);" "$W104|-CTE \"D\" $NOTUSED|X|1"
pin  "2 CONTROL WITH C .. SELECT * FROM C: no warning" "with c as (select 1 x from rdb\$database) select * from c;" "X|1"
pin  "2 CONTROL C A, C B" "with c as (select 1 x from rdb\$database) select * from c a, c b;" "X X|1 1"
refused "2 RECORDED the same table twice, unaliased, answers 36 there (a refusal here, as before)" "select count(*) from t1, t1;"
refused "2 RECORDED ...T1, T1 T1" "select count(*) from t1, t1 t1;"
refused "2 RECORDED a quoted CTE name: WITH \"c\" .. T1 C answers with the warning" "with \"c\" as (select 1 x from rdb\$database) select count(*) from t1 c;"
err_differs "2 RECORDED ...T1 \"c\" conflicts" "with \"c\" as (select 1 x from rdb\$database) select * from t1 \"c\";" "alias \"c\" $CONF"
err_differs "2 RECORDED ...C, \"C\"" "with c as (select 1 x from rdb\$database), \"C\" as (select 2 x from rdb\$database) select * from c;" "alias \"C\" $CONF"
refused "2 RECORDED a CTE read only inside a subquery" "with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select count(*) from t1 x where x.id in (select 1 from c);"
err_differs "2 RECORDED ...C, (SELECT * FROM C) C" "with c as (select 1 x from rdb\$database) select * from c, (select * from c) c;" "alias \"C\" $CONF"
err_differs "2 RECORDED a WITH inside a derived table" "select * from (with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c) d;" "alias \"C\" $CONF"
err_differs "2 RECORDED a nested WITH" "with c as (select 1 x from rdb\$database) select * from (with c as (select 2 x from rdb\$database) select * from c) d;" "WITH clause can't be nested"
err_differs "2 RECORDED an unused body's unknown column" "with c as (select nosuch from t1) select 1 from rdb\$database;" "Column unknown|-\"NOSUCH\""
err_differs "2 RECORDED an unused body's unknown table" "with c as (select 1 x from nosuch) select 1 from rdb\$database;" "Table unknown|-\"NOSUCH\""
err_differs "2 RECORDED inside an EXECUTE BLOCK" "$(eb 'execute block returns (n integer) as begin with c as (select 1 x from rdb$database), c as (select 2 x from rdb$database) select x from c into n; suspend; end')" "alias \"C\" $CONF"
err_differs "2 RECORDED CREATE VIEW" "create view vsem3 as with c as (select 1 x from rdb\$database), c as (select 2 x from rdb\$database) select * from c;" "alias \"C\" $CONF"

echo "--- 3. A QUALIFIER NOTHING BINDS: the engine's -206, first offender in pass order"
pin  "3 the member: FROM T1 T ORDER BY T1.ID" "select t.id from t1 t order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...in the select list" "select t1.id from t1 t;" "$E206|-\"T1\".\"ID\"|-At line 1, column 8"
pin  "3 ...in the WHERE" "select t.id from t1 t where t1.id = 1;" "$E206|-\"T1\".\"ID\"|-At line 1, column 29"
pin  "3 ...in the GROUP BY" "select t.a from t1 t group by t1.a;" "$E206|-\"T1\".\"A\"|-At line 1, column 31"
pin  "3 ...in a JOIN's ON" "select t.id from t1 t join t2 on t1.id = t2.t1id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 34"
pin  "3 ...in a comma join's WHERE" "select t.id from t1 t, t2 where t1.id = t2.t1id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 33"
pin  "3 ...inside a scalar subquery" "select (select t1.id from t1 t where t.id = 1) from rdb\$database;" "$E206|-\"T1\".\"ID\"|-At line 1, column 16"
pin  "3 ...inside a derived table" "select * from (select t1.id from t1 t) d;" "$E206|-\"T1\".\"ID\"|-At line 1, column 23"
pin  "3 ...inside a CTE body" "with c as (select t1.id from t1 t) select * from c;" "$E206|-\"T1\".\"ID\"|-At line 1, column 19"
pin  "3 ...a CTE's name, aliased away: C.ID FROM C X" "with c as (select id from t1) select c.id from c x;" "$E206|-\"C\".\"ID\"|-At line 1, column 38"
pin  "3 ...ORDER BY C.ID" "with c as (select id from t1) select x.id from c x order by c.id;" "$E206|-\"C\".\"ID\"|-At line 1, column 61"
pin  "3 ...FROM T1 AS T" "select t.id from t1 as t order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 35"
pin  "3 ...FROM T1 \"t\" (the alias is t, not T)" "select \"t\".id from t1 \"t\" order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 36"
pin  "3 ...T1 \"t\" WHERE T.ID" "select 1 from t1 \"t\" where t.id = 1;" "$E206|-\"T\".\"ID\"|-At line 1, column 28"
pin  "3 ...ORDER BY T1.ID DESC" "select t.id from t1 t order by t1.id desc;" "$E206|-\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...ORDER BY T1.ID + 1" "select t.id from t1 t order by t1.id + 1;" "$E206|-\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...ORDER BY \"T1\".ID" "select t.id from t1 t order by \"T1\".id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...ORDER BY UPPER(T1.V)" "select t.id from t1 t order by upper(t1.v);" "$E206|-\"T1\".\"V\"|-At line 1, column 38"
pin  "3 ...T1.V LIKE" "select t.id from t1 t where t1.v like 'a%';" "$E206|-\"T1\".\"V\"|-At line 1, column 29"
pin  "3 ...T1.ID BETWEEN" "select t.id from t1 t where t1.id between 1 and 2;" "$E206|-\"T1\".\"ID\"|-At line 1, column 29"
pin  "3 ...ROWS 2 after it" "select t.id from t1 t order by t1.id rows 2;" "$E206|-\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...FIRST 1" "select first 1 t.id from t1 t order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 40"
pin  "3 ...WITH LOCK after it (the -206 first)" "select t.id from t1 t where t1.id = 1 with lock;" "$E206|-\"T1\".\"ID\"|-At line 1, column 29"
pin  "3 ...ORDER BY T1.ID WITH LOCK" "select id from t1 t order by t1.id with lock;" "$E206|-\"T1\".\"ID\"|-At line 1, column 30"
pin  "3 ...a correlated reference to the OUTER base name" "select count(*) from t1 t where exists (select 1 from t2 where t2.t1id = t1.id);" "$E206|-\"T1\".\"ID\"|-At line 1, column 74"
pin  "3 ...T1.ID inside an IN-subquery" "select t.id from t1 t where t.id in (select t1id from t2 where t1.id > 0);" "$E206|-\"T1\".\"ID\"|-At line 1, column 64"
pin  "3 ...in a UNION's second member" "select t.id from t1 t union all select t1.id from t1 t;" "$E206|-\"T1\".\"ID\"|-At line 1, column 40"
pin  "3 ...LEFT JOIN's ON" "select t.id from t1 t left join t2 on t2.t1id = t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 49"
pin  "3 ...T2's base name behind X" "select t.id from t1 t, t2 x where t2.t1id = t.id;" "$E206|-\"T2\".\"T1ID\"|-At line 1, column 35"
pin  "3 ...in the select list, T2.ID" "select t2.id from t1 t, t2 x;" "$E206|-\"T2\".\"ID\"|-At line 1, column 8"
pin  "3 ...UPDATE T1 T .. WHERE T1.ID" "update t1 t set a = a where t1.id = 1;" "$E206|-\"T1\".\"ID\"|-At line 1, column 29"
pin  "3 ...DELETE FROM T1 T WHERE T1.ID" "delete from t1 t where t1.id = 99;" "$E206|-\"T1\".\"ID\"|-At line 1, column 24"
pin  "3 ...UPDATE: the WHERE before the SET" "update t1 t set a = t1.a where t1.id = 1;" "$E206|-\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...UPDATE: the right AND term" "update t1 t set a = 1 where t1.id = 1 and t1.a = 1;" "$E206|-\"T1\".\"A\"|-At line 1, column 43"
pin  "3 ...DELETE: the right OR term" "delete from t1 t where t1.id = 1 or t1.a = 2;" "$E206|-\"T1\".\"A\"|-At line 1, column 37"
pin  "3 a schema-qualified reference to an aliased table" "select t.id from t1 t order by public.t1.id;" "$E206|-\"PUBLIC\".\"T1\".\"ID\"|-At line 1, column 32"
pin  "3 ...FROM PUBLIC.T1 T ORDER BY T1.ID" "select t.id from public.t1 t order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 39"
pin  "3 ...the WRONG schema of an unaliased table" "select 1 from rdb\$database where public.rdb\$database.rdb\$relation_id = 0;" "$E206|-\"PUBLIC\".\"RDB\$DATABASE\".\"RDB\$RELATION_ID\"|-At line 1, column 34"
pin  "3 ...a quoted lower-case schema" "select 1 from t1 where \"public\".t1.id = 1;" "$E206|-\"public\".\"T1\".\"ID\"|-At line 1, column 24"
pin  "3 ...a name no FROM item carries" "select nosuch.id from t1;" "$E206|-\"NOSUCH\".\"ID\"|-At line 1, column 8"
pin  "3 ...RDB\$DATABASE D .. RDB\$DATABASE.X" "select 1 from rdb\$database d where rdb\$database.rdb\$relation_id = 0;" "$E206|-\"RDB\$DATABASE\".\"RDB\$RELATION_ID\"|-At line 1, column 36"
pin  "3 ...T1.* is spelled with a bare star" "select t1.* from t1 t;" "$E206|-\"T1\".*|-At line 1, column 8"
pin  "3 ...T1.RDB\$DB_KEY is spelled DB_KEY" "select t1.rdb\$db_key from t1 t;" "$E206|-\"T1\".DB_KEY|-At line 1, column 8"
pin  "3 ...a known alias, an unknown column: T.NOPE" "select t.id from t1 t order by t.nope;" "$E206|-\"T\".\"NOPE\"|-At line 1, column 32"
pin  "3 ...T1.NOPE over T1 T is the qualifier's -206" "select t.id from t1 t where t1.nope = 1;" "$E206|-\"T1\".\"NOPE\"|-At line 1, column 29"
pin  "3 CONTROL ORDER BY T.ID" "select t.id from t1 t order by t.id;" "ID|1|2|3|4|5|6"
pin  "3 CONTROL an unaliased T1 binds T1.ID" "select t1.id from t1 order by t1.id;" "ID|1|2|3|4|5|6"
pin  "3 CONTROL ...and PUBLIC.T1.ID" "select public.t1.id from public.t1;" "ID|1|2|3|4|5|6"
pin  "3 CONTROL ...\"PUBLIC\".T1.ID" "select count(*) from t1 where \"PUBLIC\".t1.id = 1;" "COUNT|1"
pin  "3 CONTROL SYSTEM.RDB\$DATABASE.X" "select 1 from rdb\$database where system.rdb\$database.rdb\$relation_id = 0;" "CONSTANT|1"
pin  "3 CONTROL a quoted upper-case alias is the bare one" "select count(*) from t1 t where \"T\".id = 1;" "COUNT|1"
pin  "3 CONTROL ...\"t\" \"t\"" "select count(*) from t1 \"t\" where \"t\".id = 1;" "COUNT|1"
pin  "3 CONTROL a bare ID" "select id from t1 t order by id;" "ID|1|2|3|4|5|6"
pin  "3 CONTROL T1 T, T1: the unaliased item binds T1.ID" "select t.id from t1 t, t1 where t.id = t1.id order by 1;" "ID|1|2|3|4|5|6"
pin  "3 CONTROL ...in the select list too" "select t.id, t1.id from t1 t, t1 where t.id = t1.id order by 1;" "ID ID|1 1|2 2|3 3|4 4|5 5|6 6"
pin  "3 CONTROL T.* answers" "select count(*) from (select t.* from t1 t);" "COUNT|6"
pin  "3 CONTROL a correlated T.ID" "select count(*) from t1 t where exists (select 1 from t2 where t2.t1id = t.id);" "COUNT|3"
pin  "3 CONTROL an ON naming the alias" "select t2.id from t1 t join t2 on t2.t1id = t.id order by t2.id;" "ID|1|2|3|6"
pin  "3 CONTROL an OUTER unaliased T1 reaches into a subquery" "select count(*) from t1 where exists (select 1 from t1 t where t1.id = t.id);" "COUNT|6"
echo "--- 3b. THE ENGINE'S PASS ORDER decides which offender is named"
pin  "3b WHERE before the select list" "select t1.id from t1 t where t1.a = 10;" "$E206|-\"T1\".\"A\"|-At line 1, column 30"
pin  "3b ...WHERE before ORDER BY" "select t.id from t1 t where t1.a = 10 order by t1.id;" "$E206|-\"T1\".\"A\"|-At line 1, column 29"
pin  "3b ...WHERE before GROUP BY" "select t.id from t1 t where t1.a = 10 group by t1.id;" "$E206|-\"T1\".\"A\"|-At line 1, column 29"
pin  "3b ...the select list before GROUP BY" "select t1.id from t1 t group by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 8"
pin  "3b ...the select list before ORDER BY" "select t1.id from t1 t order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 8"
pin  "3b ...ORDER BY before GROUP BY" "select t.id from t1 t group by t1.id order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 47"
pin  "3b ...ORDER BY before HAVING" "select t.id from t1 t group by t.id having t1.id > 0 order by t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 63"
pin  "3b ...GROUP BY before HAVING" "select t.id from t1 t where t.id = 1 group by t1.a having t1.b = 1;" "$E206|-\"T1\".\"A\"|-At line 1, column 47"
pin  "3b ...an ON before the WHERE" "select t.id from t1 t join t2 on t2.t1id = t1.id where t1.a = 10;" "$E206|-\"T1\".\"ID\"|-At line 1, column 44"
pin  "3b ...the first ON before the second" "select t.id from t1 t join t2 y on y.t1id = t1.id join t3 z on z.k = t1.a;" "$E206|-\"T1\".\"ID\"|-At line 1, column 45"
pin  "3b ...the WHERE's subquery before the select list" "select t1.a from t1 t where exists (select 1 from t2 where t2.t1id = t1.id);" "$E206|-\"T1\".\"ID\"|-At line 1, column 70"
pin  "3b ...the WHERE before the select list's subquery" "select t.id, (select t1.a from rdb\$database) from t1 t where t1.id = 1;" "$E206|-\"T1\".\"ID\"|-At line 1, column 62"
pin  "3b the RIGHT operand of AND first" "select t.id from t1 t where t.id = 1 and t1.a = 10;" "$E206|-\"T1\".\"A\"|-At line 1, column 42"
pin  "3b ...of OR" "select t.id from t1 t where t1.id = 1 or t1.a = 10;" "$E206|-\"T1\".\"A\"|-At line 1, column 42"
pin  "3b ...the LAST of a chain" "select t.id from t1 t where t.id = 1 and t1.a = 10 and t1.id = 2;" "$E206|-\"T1\".\"ID\"|-At line 1, column 56"
pin  "3b ...the same name twice: the later one" "select t.id from t1 t where t1.a = 1 and t1.a = 2;" "$E206|-\"T1\".\"A\"|-At line 1, column 42"
pin  "3b ...A = 1 AND B = 2 OR N = 3" "select t.id from t1 t where t1.a = 1 and t1.b = 2 or t1.n = 3;" "$E206|-\"T1\".\"N\"|-At line 1, column 54"
pin  "3b ...A = 1 OR B = 2 AND N = 3" "select t.id from t1 t where t1.a = 1 or t1.b = 2 and t1.n = 3;" "$E206|-\"T1\".\"N\"|-At line 1, column 54"
pin  "3b ...under NOT ( .. OR .. )" "select t.id from t1 t where not (t1.a = 1 or t1.id = 2);" "$E206|-\"T1\".\"ID\"|-At line 1, column 46"
pin  "3b ...a parenthesised group on the right" "select t.id from t1 t where t.id = 1 or (t1.a = 1 and t1.b = 2);" "$E206|-\"T1\".\"B\"|-At line 1, column 55"
pin  "3b ...inside an EXISTS body's AND" "select t.id from t1 t where exists (select 1 from t2 z where z.x = t1.a and z.id = t1.b);" "$E206|-\"T1\".\"B\"|-At line 1, column 84"
pin  "3b ...a plain term right of a subquery" "select t.id from t1 t where exists (select 1 from t2 where t2.t1id = t1.id) and t1.a = 10;" "$E206|-\"T1\".\"A\"|-At line 1, column 81"
pin  "3b ...a subquery right of a plain term" "select t.id from t1 t where t1.a = 10 and exists (select 1 from t2 where t2.t1id = t1.id);" "$E206|-\"T1\".\"ID\"|-At line 1, column 84"
pin  "3b ...in a JOIN's ON" "select t.id from t1 t left join t2 y on y.t1id = t1.id and y.x = t1.a;" "$E206|-\"T1\".\"A\"|-At line 1, column 66"
pin  "3b ...BETWEEN's AND is not a split" "select t.id from t1 t where t.id between 1 and t1.a and t.id = 1;" "$E206|-\"T1\".\"A\"|-At line 1, column 48"
pin  "3b ...a literal holding AND" "select t.id from t1 t where t.id = 1 and t1.v = 'x and y' and t1.a = 1;" "$E206|-\"T1\".\"A\"|-At line 1, column 63"
pin  "3b ...a literal holding a quote" "select t.id from t1 t where t.id = 1 and t1.v = 'x'' or' and t1.a = 1;" "$E206|-\"T1\".\"A\"|-At line 1, column 62"
pin  "3b a comparison's LEFT side first" "select t.id from t1 t where t1.a = t1.id;" "$E206|-\"T1\".\"A\"|-At line 1, column 29"
pin  "3b ...T.ID = T1.ID" "select t.id from t1 t where t.id = t1.id;" "$E206|-\"T1\".\"ID\"|-At line 1, column 36"
pin  "3b ...UPPER(T1.V) = T1.V" "select t.id from t1 t where upper(t1.v) = t1.v;" "$E206|-\"T1\".\"V\"|-At line 1, column 35"
pin  "3b ...T1.A IN (1, T1.ID)" "select t.id from t1 t where t1.a in (1, t1.id);" "$E206|-\"T1\".\"A\"|-At line 1, column 29"
pin  "3b ...T1.A = (SELECT MAX(T1.ID) ..): the left" "select t.id from t1 t where t1.a = (select max(t1.id) from t2);" "$E206|-\"T1\".\"A\"|-At line 1, column 29"
pin  "3b ...T1.A IN (SELECT T1.B ..): the SUBQUERY" "select t.id from t1 t where t1.a in (select t1.b from t2 z);" "$E206|-\"T1\".\"B\"|-At line 1, column 45"
pin  "3b ...COALESCE's first argument" "select coalesce(t1.a, t1.id) from t1 t;" "$E206|-\"T1\".\"A\"|-At line 1, column 17"
pin  "3b ...HAVING MAX(T1.A) > T1.ID" "select t.id from t1 t group by t.id having max(t1.a) > t1.id;" "$E206|-\"T1\".\"A\"|-At line 1, column 48"
pin  "3b ...COUNT(*) .. HAVING MAX(T1.A) reaches the HAVING" "select count(*) from t1 t having max(t1.a) > 0;" "$E206|-\"T1\".\"A\"|-At line 1, column 38"
pin  "3b an arithmetic's RIGHT operand first" "select t1.a + t1.id from t1 t;" "$E206|-\"T1\".\"ID\"|-At line 1, column 15"
pin  "3b ...T1.A * 2 + T1.ID" "select t1.a * 2 + t1.id from t1 t;" "$E206|-\"T1\".\"ID\"|-At line 1, column 19"
pin  "3b ...T1.A || T1.V" "select t1.a || t1.v from t1 t;" "$E206|-\"T1\".\"V\"|-At line 1, column 16"
pin  "3b ...inside a comparison's left side" "select t.id from t1 t where t1.a + t1.id > 0;" "$E206|-\"T1\".\"ID\"|-At line 1, column 36"
pin  "3b ...a negation's operand" "select t.id from t1 t where -t1.a > t1.id;" "$E206|-\"T1\".\"A\"|-At line 1, column 30"
pin  "3b the select list in text order" "select t1.id, t1.a from t1 t;" "$E206|-\"T1\".\"ID\"|-At line 1, column 8"
pin  "3b ...ORDER BY in text order" "select t.id from t1 t order by t.id, t1.a desc, t1.b;" "$E206|-\"T1\".\"A\"|-At line 1, column 38"
pin  "3b ...GROUP BY in text order" "select t.id from t1 t group by t.id, t1.a, t1.b;" "$E206|-\"T1\".\"A\"|-At line 1, column 38"
pin  "3b ...a select-list subquery AFTER the plain items" "select (select t1.a from rdb\$database), t1.b from t1 t;" "$E206|-\"T1\".\"B\"|-At line 1, column 41"
pin  "3b ...the first UNION member first" "select t.id from t1 t where t1.a = 1 union all select t.id from t1 t where t1.b = 2;" "$E206|-\"T1\".\"A\"|-At line 1, column 29"
err_differs "3 RECORDED the THEN branch of a CASE is read before its condition" "select t.id from t1 t where case when t1.a = 1 then t1.b else 0 end > 0;" "column 53"
err_differs "3 RECORDED a UNION's ORDER BY is the union's -104" "select t.id from t1 t union all select t.id from t1 t order by t1.id;" "invalid ORDER BY clause"
err_differs "3 RECORDED a plain column beside a HAVING is the select list's -104" "select t.id from t1 t having t1.id = 1;" "Invalid expression in the select list"
err_differs "3 RECORDED a bare unknown column" "select t.id from t1 t where nosuch = 1;" "Column unknown|-\"NOSUCH\""
err_differs "3 RECORDED inside an EXECUTE BLOCK" "$(eb 'execute block returns (n integer) as begin select first 1 t.id from t1 t order by t1.id into n; suspend; end')" "\"T1\".\"ID\"|-At line 1, column 83"
err_differs "3 RECORDED CREATE VIEW" "create view vsem as select t.id from t1 t order by t1.id;" "\"T1\".\"ID\"|-At line 1, column 52"

echo "--- 4. A RECURSIVE MEMBER's shape, judged when the CTE is added"
RB="with recursive r (n) as (select 1 from rdb\$database union all"
pin  "4 the member: R LEFT JOIN T3" "$RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...T3 LEFT JOIN R" "$RB select r.n + 1 from t3 left join r on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...T3 RIGHT JOIN R" "$RB select r.n + 1 from t3 right join r on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...R RIGHT JOIN T3" "$RB select r.n + 1 from r right join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...R FULL JOIN T3" "$RB select r.n + 1 from r full join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...LEFT OUTER" "$RB select r.n + 1 from r left outer join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...an outer join OVER the inner one that holds R" "$RB select r.n + 1 from r join t3 on t3.k = r.n left join t2 on t2.id = t3.k where r.n < 3) select * from r;" "$OJ"
pin  "4 ...T2 JOIN T3 LEFT JOIN R" "$RB select r.n + 1 from t2 join t3 on 1 = 1 left join r on r.n = t3.k where r.n < 3) select * from r;" "$OJ"
pin  "4 ...R LEFT JOIN T3 CROSS JOIN T2 (the outer join first)" "$RB select r.n + 1 from r left join t3 on t3.k = r.n cross join t2 where r.n < 3) select * from r;" "$OJ"
pin  "4 ...T2 CROSS JOIN T3 LEFT JOIN R" "$RB select r.n + 1 from t2 cross join t3 left join r on r.n = t3.k where r.n < 3) select * from r;" "$OJ"
pin  "4 ...before DISTINCT" "$RB select distinct r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...before an aggregate" "$RB select max(r.n) + 1 from r left join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...R LEFT JOIN R R2: the join first" "$RB select r.n + 1 from r left join r r2 on r2.n = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...a bare UNION link: the join first" "with recursive r (n) as (select 1 from rdb\$database union select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...in a third member" "$RB select r.n + 1 from r where r.n < 3 union all select r.n + 5 from r left join t3 on t3.k = r.n where r.n < 3) select * from r;" "$OJ"
pin  "4 ...the main reads COUNT(*)" "$RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select count(*) from r;" "$OJ"
pin  "4 ...the main reads NOTHING of it: judged at add time" "$RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select 1 from rdb\$database;" "$OJ"
pin  "4 ...WHERE 0 = 1" "$RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select 1 from rdb\$database where 0 = 1;" "$OJ"
pin  "4 ...a second CTE is read instead" "$RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3), s as (select 1 y from rdb\$database) select * from s;" "$OJ"
pin  "4 ...R sound, S with the outer join, R read" "$RB select r.n + 1 from r where r.n < 3), s (m) as (select 1 from rdb\$database union all select s.m + 1 from s left join t3 on t3.k = s.m where s.m < 3) select * from r;" "$OJ"
pin  "4 ...a second R after it" "$RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3), r as (select 2 from rdb\$database) select * from r;" "$OJ"
pin  "4 ...no WHERE at all (no bound to hit first)" "$RB select r.n + 1 from r left join t3 on t3.k = r.n) select * from r;" "$OJ"
pin  "4 CONTROL R JOIN T3" "$RB select r.n + 1 from r join t3 on t3.k = r.n where r.n < 3) select * from r;" "N|1|2|3|2|3"
pin  "4 CONTROL R INNER JOIN T3" "$RB select r.n + 1 from r inner join t3 on t3.k = r.n where r.n < 3) select * from r;" "N|1|2|3|2|3"
pin  "4 CONTROL R, T3" "$RB select r.n + 1 from r, t3 where t3.k = r.n and r.n < 3) select * from r;" "N|1|2|3|2|3"
pin  "4 CONTROL R, T3 LEFT JOIN T2: the outer join is another item's" "$RB select r.n + 1 from r, t3 left join t2 on t2.id = t3.k where r.n < 3 and t3.k = r.n) select * from r;" "N|1|2|3|2|3"
pin  "4 CONTROL T3 LEFT JOIN T2, R" "$RB select r.n + 1 from t3 left join t2 on t2.id = t3.k, r where r.n < 3 and t3.k = r.n) select * from r;" "N|1|2|3|2|3"
pin  "4 CONTROL an outer join inside an EXISTS" "$RB select r.n + 1 from r where r.n < 3 and exists (select 1 from t3 left join t2 on t2.id = t3.k where t3.k = r.n)) select * from r;" "N|1|2|3"
pin  "4 CONTROL an outer join in the ANCHOR" "with recursive r (n) as (select t3.k from t3 left join t2 on t2.id = t3.k union all select r.n + 1 from r where r.n < 3) select * from r;" "N|1|2|3|2|3|<null>|1|2|3"
echo "--- 4b. THE OTHER MEMBER CHECKS, in the measured order"
pin  "4b an aggregate" "$RB select max(r.n) + 1 from r where r.n < 3) select * from r;" "$R104|-Recursive member of CTE cannot use aggregate or window function"
pin  "4b ...a window function" "$RB select row_number() over () from r where r.n < 3) select * from r;" "$R104|-Recursive member of CTE cannot use aggregate or window function"
pin  "4b DISTINCT" "$RB select distinct r.n + 1 from r where r.n < 3) select * from r;" "$R104|-Recursive member of CTE 'R' has DISTINCT clause"
pin  "4b ...DISTINCT before the aggregate" "$RB select distinct max(r.n) from r where r.n < 3) select * from r;" "$R104|-Recursive member of CTE 'R' has DISTINCT clause"
pin  "4b ...DISTINCT before GROUP BY" "$RB select distinct r.n + 1 from r where r.n < 3 group by r.n) select * from r;" "$R104|-Recursive member of CTE 'R' has DISTINCT clause"
pin  "4b ...DISTINCT before a subquery reference" "$RB select distinct r.n + 1 from r where r.n < (select max(n) from r)) select * from r;" "$R104|-Recursive member of CTE 'R' has DISTINCT clause"
pin  "4b ...DISTINCT before the bare UNION link" "with recursive r (n) as (select 1 from rdb\$database union select distinct r.n + 1 from r where r.n < 3) select * from r;" "$R104|-Recursive member of CTE 'R' has DISTINCT clause"
pin  "4b GROUP BY" "$RB select r.n + 1 from r where r.n < 3 group by r.n) select * from r;" "$R104|-Recursive member of CTE 'R' has GROUP BY clause"
pin  "4b ...GROUP BY before HAVING" "$RB select r.n + 1 from r where r.n < 3 group by r.n having count(*) > 0) select * from r;" "$R104|-Recursive member of CTE 'R' has GROUP BY clause"
pin  "4b HAVING" "$RB select r.n + 1 from r where r.n < 3 having 1 = 1) select * from r;" "$R104|-Recursive member of CTE 'R' has HAVING clause"
pin  "4b a second self-reference: R, R R2" "$RB select r.n + 1 from r, r r2 where r.n < 3) select * from r;" "$R104|-Recursive member of CTE can't reference itself more than once"
pin  "4b ...before DISTINCT" "$RB select distinct r.n + 1 from r, r r2 where r.n < 3) select * from r;" "$R104|-Recursive member of CTE can't reference itself more than once"
pin  "4b ...before an aggregate" "$RB select max(r.n) from r, r r2 where r.n < 3) select * from r;" "$R104|-Recursive member of CTE can't reference itself more than once"
pin  "4b ...before a subquery reference" "$RB select r.n + 1 from r, r r2 where r.n < (select max(n) from r)) select * from r;" "$R104|-Recursive member of CTE can't reference itself more than once"
pin  "4b a reference inside a subquery" "$RB select r.n + 1 from r where r.n < (select max(n) from r)) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b ...an EXISTS" "$RB select r.n + 1 from r where exists (select 1 from r)) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b ...a derived table" "$RB select r.n + 1 from r, (select 1 x from r) d where r.n < 3) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b ...only in a subquery, no FROM item at all" "$RB select 2 from rdb\$database where exists (select 1 from r)) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b ...R CROSS JOIN T3 reports the same" "$RB select r.n + 1 from r cross join t3 where r.n < 3 and t3.k = 1) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b ...T3 CROSS JOIN R" "$RB select r.n + 1 from t3 cross join r where r.n < 3 and t3.k = 1) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b ...R NATURAL JOIN T3" "$RB select r.n + 1 from r natural join t3 where r.n < 3) select * from r;" "$R104|-Recursive CTE member (\"R\") can refer itself only in FROM clause"
pin  "4b a bare UNION link" "with recursive r (n) as (select 1 from rdb\$database union select r.n + 1 from r where r.n < 3) select * from r;" "$R104|-Recursive members of CTE (R) must be linked with another members via UNION ALL"
pin  "4b ...after a UNION ALL member" "$RB select r.n + 1 from r where r.n < 3 union select r.n + 1 from r where r.n < 3) select * from r;" "$R104|-Recursive members of CTE (R) must be linked with another members via UNION ALL"
pin  "4b a non-recursive member after a recursive one" "$RB select r.n + 1 from r where r.n < 3 union select 5 from rdb\$database) select * from r;" "$R104|-CTE 'R' defined non-recursive member after recursive"
pin  "4b ...linked by UNION ALL too" "$RB select r.n + 1 from r where r.n < 3 union all select 9 from rdb\$database) select * from r;" "$R104|-CTE 'R' defined non-recursive member after recursive"
pin  "4b ...the FIRST member recursive, then an anchor" "with recursive r (n) as (select r.n from r union all select 1 from rdb\$database) select * from r;" "$R104|-CTE 'R' defined non-recursive member after recursive"
pin  "4b ...under a bare UNION" "with recursive r (n) as (select r.n from r union select 1 from rdb\$database) select * from r;" "$R104|-CTE 'R' defined non-recursive member after recursive"
pin  "4b no anchor at all" "with recursive r (n) as (select r.n from r union all select r.n from r) select * from r;" "$R104|-Non-recursive member is missing in CTE 'R'"
pin  "4b no union at all" "with recursive r (n) as (select r.n from r) select * from r;" "$R104|-Recursive CTE (R) must be an UNION"
refused "4b RECORDED a bare UNION among the ANCHORS is legal (two anchors refuse here, as before)" "with recursive r (n) as (select 1 from rdb\$database union select 2 from rdb\$database union all select r.n + 10 from r where r.n < 2) select count(*) from r;"
refused "4 RECORDED R JOIN (T3 LEFT JOIN T2): a parenthesised join" "$RB select r.n + 1 from r join (t3 left join t2 on t2.id = t3.k) on t3.k = r.n where r.n < 3) select * from r;"
refused "4 RECORDED R JOIN (a derived table with an outer join)" "$RB select r.n + 1 from r join (select t3.k from t3 left join t2 on t2.id = t3.k) d on d.k = r.n where r.n < 3) select * from r;"
err_differs "4 RECORDED (R JOIN T3) LEFT JOIN T2" "$RB select r.n + 1 from (r join t3 on t3.k = r.n) left join t2 on t2.id = t3.k where r.n < 3) select * from r;" "outer join"
err_differs "4 RECORDED R LEFT JOIN T3 USING (K)" "$RB select r.n + 1 from r left join t3 using (k) where r.n < 3) select * from r;" "outer join"
refused "4 RECORDED two recursive members" "$RB select r.n + 1 from r where r.n < 2 union all select r.n + 10 from r where r.n < 2) select * from r;"
refused "4 RECORDED FIRST 1 in a member" "$RB select first 1 r.n + 1 from r where r.n < 3) select * from r;"
refused "4 RECORDED a subquery beside the reference" "$RB select r.n + 1 from r where r.n < 3 and r.n in (select k from t3)) select * from r;"
refused "4 RECORDED two recursive CTEs, one read" "$RB select r.n + 1 from r where r.n < 3), s (m) as (select 1 from rdb\$database union all select s.m + 1 from s where s.m < 3) select * from r;"
refused "4 RECORDED a sound recursive CTE left unread (the engine warns and answers)" "$RB select r.n + 1 from r inner join t3 on t3.k = r.n where r.n < 3) select 1 from rdb\$database;"
err_differs "4 RECORDED a second R after a sound one" "$RB select r.n + 1 from r where r.n < 3), r as (select 2 from rdb\$database) select * from r;" "alias \"R\" $CONF"
err_differs "4 RECORDED inside a derived table" "select * from ($RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select * from r) d;" "outer join"
err_differs "4 RECORDED inside an EXECUTE BLOCK" "$(eb "execute block returns (n integer) as begin for $RB select r.n + 1 from r left join t3 on t3.k = r.n where r.n < 3) select n from r into :n do suspend; end")" "outer join"

echo "--- 5. WITH LOCK over a relation the request parser refuses"
pin  "5 the member: SELECT 1 FROM RDB\$DATABASE WITH LOCK" "select 1 from rdb\$database with lock;" "$HY|$SYSDB"
pin  "5 ...SELECT *" "select * from rdb\$database with lock;" "$HY|$SYSDB"
pin  "5 ...RDB\$RELATIONS with a WHERE" "select rdb\$relation_name from rdb\$relations where rdb\$relation_id = 0 with lock;" "$HY|Cannot select system table \"SYSTEM\".\"RDB\$RELATIONS\" for update WITH LOCK"
pin  "5 ...FOR UPDATE WITH LOCK" "select rdb\$relation_name from rdb\$relations where rdb\$relation_id = 0 for update with lock;" "$HY|Cannot select system table \"SYSTEM\".\"RDB\$RELATIONS\" for update WITH LOCK"
pin  "5 ...SKIP LOCKED" "select 1 from rdb\$database with lock skip locked;" "$HY|$SYSDB"
pin  "5 ...a VIRTUAL table: MON\$ATTACHMENTS" "select mon\$attachment_id from mon\$attachments with lock;" "$HY|Cannot select virtual table \"SYSTEM\".\"MON\$ATTACHMENTS\" for update WITH LOCK"
pin  "5 ...SEC\$USERS" "select sec\$user_name from sec\$users with lock;" "$HY|Cannot select virtual table \"SYSTEM\".\"SEC\$USERS\" for update WITH LOCK"
pin  "5 ...FIRST 1 * FROM MON\$DATABASE" "select first 1 * from mon\$database with lock;" "$HY|Cannot select virtual table \"SYSTEM\".\"MON\$DATABASE\" for update WITH LOCK"
pin  "5 ...RDB\$FIELDS WHERE 0 = 1" "select rdb\$field_name from rdb\$fields where 0 = 1 with lock;" "$HY|Cannot select system table \"SYSTEM\".\"RDB\$FIELDS\" for update WITH LOCK"
pin  "5 ...a TEMPORARY table: ON COMMIT DELETE ROWS" "select * from gtd with lock;" "$HY|Cannot select temporary table \"PUBLIC\".\"GTD\" for update WITH LOCK"
pin  "5 ...ON COMMIT PRESERVE ROWS" "select * from gtp with lock;" "$HY|Cannot select temporary table \"PUBLIC\".\"GTP\" for update WITH LOCK"
pin  "5 ...GTD FOR UPDATE WITH LOCK" "select * from gtd for update with lock;" "$HY|Cannot select temporary table \"PUBLIC\".\"GTD\" for update WITH LOCK"
pin  "5 ...aliased" "select 1 from rdb\$database d with lock;" "$HY|$SYSDB"
pin  "5 ...schema-qualified" "select 1 from \"SYSTEM\".rdb\$database with lock;" "$HY|$SYSDB"
pin  "5 ...ORDER BY" "select 1 from rdb\$database order by 1 with lock;" "$HY|$SYSDB"
pin  "5 ...ROWS 1" "select 1 from rdb\$database rows 1 with lock;" "$HY|$SYSDB"
pin  "5 ...FIRST 1" "select first 1 1 from rdb\$database with lock;" "$HY|$SYSDB"
pin  "5 ...WHERE 0 = 1: at prepare, no header" "select 1 from rdb\$database where 0 = 1 with lock;" "$HY|$SYSDB"
pin  "5 ...FOR UPDATE OF" "select 1 from rdb\$database for update of rdb\$relation_id with lock;" "$HY|$SYSDB"
pin  "5 ...a real column" "select rdb\$relation_id from rdb\$database with lock;" "$HY|$SYSDB"
pin  "5 ...RDB\$TYPES with a WHERE matching nothing" "select * from rdb\$types where rdb\$field_name = 'NOPE' with lock;" "$HY|Cannot select system table \"SYSTEM\".\"RDB\$TYPES\" for update WITH LOCK"
pin  "5 ...RDB\$RELATIONS by name" "select rdb\$relation_id from rdb\$relations where rdb\$relation_name = 'T1' with lock;" "$HY|Cannot select system table \"SYSTEM\".\"RDB\$RELATIONS\" for update WITH LOCK"
echo "--- 5b. AFTER every DSQL check, and never for a chain"
pin  "5b COUNT(*) is the aggregates message" "select count(*) from rdb\$database with lock;" "$R104|-WITH LOCK cannot be used with aggregates"
pin  "5b ...GROUP BY too" "select * from rdb\$database group by rdb\$relation_id with lock;" "$R104|-WITH LOCK cannot be used with aggregates"
pin  "5b ...DISTINCT" "select distinct 1 from rdb\$database with lock;" "$R104|-WITH LOCK cannot be used with DISTINCT"
pin  "5b ...two tables" "select 1 from rdb\$database, rdb\$relations with lock;" "$R104|-WITH LOCK can be used only with a single physical table"
pin  "5b ...a JOIN" "select rdb\$relation_id from rdb\$database join rdb\$relations on 1 = 1 with lock;" "$R104|-WITH LOCK can be used only with a single physical table"
pin  "5b ...a derived table" "select * from (select 1 x from rdb\$database) with lock;" "$R104|-WITH LOCK can be used only with a single physical table"
pin  "5b ...a CTE" "with c as (select 1 x from rdb\$database) select * from c with lock;" "$R104|-WITH LOCK can be used only with a single physical table"
pin  "5b ...a view over the system table" "select * from sysv with lock;" "$R104|-WITH LOCK can be used only with a single physical table"
pin  "5b a UNION ALL chain over the system table is LOCKED" "select 1 from rdb\$database union all select 1 from rdb\$database with lock;" "CONSTANT|1|1"
pin  "5b ...the -206 first" "select 1 from rdb\$database t where t1.id = 1 with lock;" "$E206|-\"T1\".\"ID\"|-At line 1, column 36"
pin  "5b ...the -204 first: FROM NOSUCH" "select 1 from nosuch with lock;" "Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-\"NOSUCH\"|-At line 1, column 15"
pin  "5b ...RDB\$DATABASE, NOSUCH" "select 1 from rdb\$database, nosuch with lock;" "Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-\"NOSUCH\"|-At line 1, column 29"
pin  "5b CONTROL a user table locks" "select id from t1 where id = 1 with lock;" "ID|1"
pin  "5b CONTROL ...FOR UPDATE WITH LOCK" "select id from t1 where id = 1 for update with lock;" "ID|1"
pin  "5b CONTROL ...every row" "select 1 from t1 with lock;" "CONSTANT|1|1|1|1|1|1"
pin  "5b CONTROL no lock" "select 1 from rdb\$database;" "CONSTANT|1"
pin  "5b CONTROL FOR UPDATE alone is taken" "select 1 from rdb\$database for update;" "CONSTANT|1"
err_differs "5 RECORDED a bare unknown column under WITH LOCK" "select nosuch from rdb\$database with lock;" "Column unknown|-\"NOSUCH\""
err_differs "5 RECORDED ...in the WHERE" "select 1 from rdb\$database where nosuch = 1 with lock;" "Column unknown|-\"NOSUCH\""
err_differs "5 RECORDED inside an EXECUTE BLOCK" "$(eb 'execute block returns (n integer) as begin select 1 from rdb$database with lock into n; suspend; end')" "$SYSDB"
err_differs "5 RECORDED ...FOR SELECT" "$(eb 'execute block returns (n integer) as begin for select 1 from rdb$database with lock into :n do suspend; end')" "$SYSDB"
err_differs "5 RECORDED CREATE PROCEDURE" "$(eb 'create procedure psem2 returns (n integer) as begin select 1 from rdb$database with lock into n; suspend; end')" "$SYSDB"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-semchk-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 300 ]; then echo "FAIL only $ran checks ran (floor 300)"; fail=1; fi
exit $fail
