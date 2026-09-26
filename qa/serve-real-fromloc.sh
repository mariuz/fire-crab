#!/bin/bash
# A FROM THAT IS NO FROM CLAUSE - AND THE FUNCTIONS WHOSE GRAMMAR SPELLS
# ONE. The engine's grammar writes FROM in four places besides the
# clause, and every FROM locator in this server (the select splitter,
# the unknown-relation fallback, the LIMIT lint, the DML scans) read
# each as the start of the FROM clause, so a statement the engine
# answers was refused with a made-up -204 *Table unknown* naming the
# next word ("1", "LAST", "DATE", "FALSE", "'B'"), measured on 2182:
#
#   * inside a function's operand list - SUBSTRING, TRIM, EXTRACT,
#     DATEDIFF were known; OVERLAY(s PLACING p FROM n [FOR len]) and
#     FIRST_DAY / LAST_DAY(OF <part> FROM d) were not;
#   * `<x> IS [NOT] DISTINCT FROM <y>` at any depth - a select list, a
#     WHERE, a PSQL IF / WHILE / IIF / CASE;
#   * `NTH_VALUE(v, n) FROM FIRST | FROM LAST OVER (...)`;
#   * and `FROM <word> OVER`, that spelling gone wrong (the engine's
#     -104; a refusal here, never a table named LAST).
#
# ONE LAW, [from_is_clause], is asked by every locator now, and the
# functions behind the FROMs are answered:
#
#   1. OVERLAY - evlOverlay's law: the characters before n, the placing
#      string, the rest from n + len (len defaults to the placing
#      string's length, both clamp to the end); a NULL anywhere is NULL
#      before any check, then a negative len (#4) and a start below 1
#      (#3) raise at FETCH; VARYING as wide as both operands (makeOverlay),
#      CHAR(1) for a bare NULL argument.
#   2. EXTRACT(QUARTER FROM d) - SMALLINT 1..4 over a DATE / TIMESTAMP,
#      the -105 over a TIME.
#   3. FIRST_DAY / LAST_DAY(OF YEAR | QUARTER | MONTH | WEEK FROM d) - a
#      DATE answers a DATE, a TIMESTAMP keeps its time of day (and its
#      zone), a week runs Sunday..Saturday; a TIME or a string is
#      described DATE and raises "Expected DATE/TIMESTAMP value" at
#      fetch; 0001-01-01's week start is 22008.
#   4. NTH_VALUE ... FROM LAST counts back from the frame's END; FROM
#      FIRST is the plain NTH_VALUE.
#   5. IS [NOT] DISTINCT FROM in an EXECUTE BLOCK: the procedure
#      compiler (crates/dsql) had no such predicate and refused the
#      block; it compiles to blr_equiv, and IS DISTINCT to blr_not over
#      it, the parser's own shape - the same compiler writes a VIEW's
#      BLR, so CREATE VIEW over the predicate answers now too, its
#      RDB$VIEW_BLR byte-identical to the engine's (read back by 2182).
#
# RECORDED, not fixed (every one a refusal here, never a wrong answer):
# LIST() inside an expression (a blob result, the recorded boundary of
# the aggregate router); a VIEW whose select item is the predicate, or
# over OVERLAY (the view compiler has neither); OVERLAY / EXTRACT / FIRST_DAY in a PSQL
# assignment (the procedure compiler knows none of the system functions
# but SUBSTRING / TRIM / the casts - EXTRACT(YEAR ..) refuses there the
# same way); OVERLAY over two different character sets; DATEADD /
# DATEDIFF with QUARTER (the engine's fetch-time "Invalid part");
# an unordered NTH_VALUE window; a TRUE / FALSE literal in an EXECUTE
# BLOCK (the procedure compiler has none - `IF (TRUE IS DISTINCT FROM
# FALSE)` refuses for that, no longer as -204 "FALSE"); and the engine's
# parser -104s (an
# unknown EXTRACT part, FIRST_DAY(OF DAY ..), a direction on another
# window function, FOO(1 FROM 2)) where this server says a bare 42000 or
# -804.
#
# Usage: qa/serve-real-fromloc.sh [port]   (default 5710)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5710}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/fromloc-eng.fdb"; FC="$D/fromloc-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
create table w (id integer, g integer, val integer);
create table d (id integer, dt date, ts timestamp, s varchar(20), n integer, tz timestamp with time zone);
create table t (v varchar(5));
create table "FROM" (id integer, "FROM" varchar(10));
create table u8 (u varchar(10) character set utf8, w varchar(10) character set win1252);
insert into w values (1, 1, 10);
insert into w values (2, 1, 20);
insert into w values (3, 1, 30);
insert into w values (4, 2, 40);
insert into w values (5, 2, null);
insert into w values (6, 2, 60);
insert into d values (1, date '2024-05-17', timestamp '2024-02-10 13:14:15.1234', 'hello world', 2, timestamp '2024-02-10 13:14:15 Europe/Paris');
insert into d values (2, date '2024-02-10', null, null, null, null);
insert into d values (3, date '2023-12-31', timestamp '2023-01-01 00:00:00', 'abc', 5, timestamp '2023-12-31 23:30:00 America/New_York');
insert into t values ('b');
insert into t values ('a');
insert into "FROM" values (1, 'x');
insert into u8 values ('abc', 'def');
COMMIT;
create view vo as select id, overlay(s placing 'Z' from 1 for 1) o, extract(quarter from dt) q, first_day(of month from dt) f from d;
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/fromloc-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/fromloc-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/fromloc-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-fromloc-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | grep -av '^At line' \
    | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# an EXECUTE BLOCK script, terminators switched
eb() { printf 'SET TERM ^;\n%s^\nSET TERM ;^\n' "$1"; }
# the ENGINE is pinned, and this server agrees
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
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    elif [ "${fv#*Table unknown}" != "$fv" ]; then echo "FAIL $1 - a made-up Table unknown [$fv]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server refuses)"; fi
}
# BOTH RAISE, with different vectors - the engine's pinned whole, this
# server's a refusal that is no made-up -204
err_differs() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    elif [ "${fv#*Table unknown}" != "$fv" ]; then echo "FAIL $1 - a made-up Table unknown [$fv]"; fail=1
    else echo "OK   $1 (recorded vector gap: engine [${ev:0:70}])"; fi
}
SQLDA='set sqlda_display on;'

pin  "0 the fixture" "select count(*) from w;" "COUNT|6"

echo "--- 1. OVERLAY(s PLACING p FROM n [FOR len]) - the FROM was the clause's"
pin  "1 the member: a literal (was -204 \"1\")" "select overlay('abc' placing 'x' from 1) from rdb\$database;" "OVERLAY|xbc"
pin  "1 FOR a shorter span" "select overlay('abcdef' placing 'xy' from 2 for 3) from rdb\$database;" "OVERLAY|axyef"
pin  "1 no FOR: the placing string's length" "select overlay('abcdef' placing 'xy' from 2) from rdb\$database;" "OVERLAY|axydef"
pin  "1 FOR 0 inserts" "select overlay('abcdef' placing 'xy' from 2 for 0) from rdb\$database;" "OVERLAY|axybcdef"
pin  "1 FOR past the end clamps" "select overlay('abcdef' placing 'xy' from 5 for 10) from rdb\$database;" "OVERLAY|abcdxy"
pin  "1 a start past the end appends" "select overlay('abcdef' placing 'xy' from 10) from rdb\$database;" "OVERLAY|abcdefxy"
pin  "1 an empty placing string" "select overlay('abcdef' placing '' from 2) from rdb\$database;" "OVERLAY|abcdef"
pin  "1 a start of 0 is #3 at fetch" "select overlay('abcdef' placing 'xy' from 0) from rdb\$database;" "OVERLAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument #3 for OVERLAY must be positive"
pin  "1 a negative start" "select overlay('abcdef' placing 'xy' from -1) from rdb\$database;" "OVERLAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument #3 for OVERLAY must be positive"
pin  "1 a negative FOR is #4" "select overlay('abcdef' placing 'xy' from 2 for -1) from rdb\$database;" "OVERLAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument #4 for OVERLAY must be zero or positive"
pin  "1 FOR is checked before the start" "select overlay('abc' placing 'x' from 0 for -1) from rdb\$database;" "OVERLAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument #4 for OVERLAY must be zero or positive"
pin  "1 a NULL start before any check" "select overlay('abc' placing 'x' from null for -1) from rdb\$database;" "OVERLAY|<null>"
pin  "1 a NULL FOR before the start's check" "select overlay('abc' placing 'x' from 0 for null) from rdb\$database;" "OVERLAY|<null>"
pin  "1 a NULL source" "select overlay(null placing 'xy' from 1) from rdb\$database;" "OVERLAY|<null>"
pin  "1 a NULL placing string" "select overlay('abc' placing null from 1) from rdb\$database;" "OVERLAY|<null>"
pin  "1 two numbers are text" "select overlay(12345 placing 9 from 2) from rdb\$database;" "OVERLAY|19345"
pin  "1 a scaled start rounds" "select overlay('abcdef' placing 'xy' from 2.6) from rdb\$database;" "OVERLAY|abxyef"
pin  "1 a string start converts" "select overlay('abcdef' placing 'xy' from '2') from rdb\$database;" "OVERLAY|axydef"
pin  "1 a start past INTEGER" "select overlay('abc' placing 'x' from 2147483648) from rdb\$database;" "OVERLAY|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin  "1 a start that is no number" "select overlay('abc' placing 'x' from 'q') from rdb\$database;" "OVERLAY|Statement failed, SQLSTATE = 22018|conversion error from string \"q\""
pin  "1 described VARYING, both widths" "$SQLDA select overlay('abcdef' placing 'xy' from 2) from rdb\$database;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 8 charset: 0 SYSTEM.NONE|: name: OVERLAY alias: OVERLAY|: table: schema: owner:|OVERLAY|axydef"
pin  "1 described over a column, nullable" "$SQLDA select overlay(s placing 'Q' from 1) from d where id = 1;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 21 charset: 0 SYSTEM.NONE|: name: OVERLAY alias: OVERLAY|: table: schema: owner:|OVERLAY|Qello world"
pin  "1 described CHAR(1) for a NULL argument" "$SQLDA select overlay('abc' placing 'x' from null) from rdb\$database;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|: name: OVERLAY alias: OVERLAY|: table: schema: owner:|OVERLAY|<null>"
pin  "1 over a column" "select id, overlay(s placing 'Q' from 7 for 5) from d order by id;" "ID OVERLAY|1 hello Q|2 <null>|3 abcQ"
pin  "1 column arguments" "select id, overlay(s placing 'x' from n for n) from d order by id;" "ID OVERLAY|1 hxlo world|2 <null>|3 abcx"
pin  "1 in WHERE" "select id from d where overlay(s placing 'J' from 1 for 1) = 'Jello world';" "ID|1"
pin  "1 in ORDER BY" "select id from d order by overlay(s placing 'z' from 1 for 1), id;" "ID|2|3|1"
pin  "1 nested" "select overlay(overlay(s placing 'a' from 1) placing 'b' from 2) from d order by id;" "OVERLAY|abllo world|<null>|abc"
pin  "1 under SUBSTRING" "select substring(overlay(s placing 'XY' from 3 for 0) from 1 for 6) from d order by id;" "SUBSTRING|heXYll|<null>|abXYc"
pin  "1 concatenated and measured" "select overlay('abc' placing 'x' from 1) || '!', char_length(overlay('abcdef' placing 'xyz' from 2 for 1)) from rdb\$database;" "CONCATENATION CHAR_LENGTH|xbc! 8"
pin  "1 in a scalar subquery" "select (select overlay(s placing '#' from 2) from d where id = 3) from rdb\$database;" "OVERLAY|a#c"
pin  "1 in a CTE" "with c as (select id, overlay(s placing 'Q' from 1 for 0) o from d) select * from c order by id;" "ID O|1 Qhello world|2 <null>|3 Qabc"
pin  "1 over a UTF8 column and an ASCII literal" "select overlay(u placing 'Z' from 2) from u8;" "OVERLAY|aZc"

echo "--- 2. EXTRACT(QUARTER FROM d) - was -204 \"DATE\""
pin  "2 the member" "select extract(quarter from date '2024-05-01') from rdb\$database;" "EXTRACT|2"
pin  "2 a TIMESTAMP's last day" "select extract(quarter from timestamp '2024-12-31 10:00:00') from rdb\$database;" "EXTRACT|4"
pin  "2 described SMALLINT" "$SQLDA select extract(quarter from dt) from d where id = 1;" "INPUT message field count: 0|OUTPUT message field count: 1|01: sqltype: 500 SHORT Nullable scale: 0 subtype: 0 len: 2|: name: EXTRACT alias: EXTRACT|: table: schema: owner:|EXTRACT|2"
pin  "2 a TIME is the -105" "select extract(quarter from time '10:00:00') from rdb\$database;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -105|-Specified EXTRACT part does not exist in input datatype"
pin  "2 a typed NULL" "select extract(quarter from cast(null as date)) from rdb\$database;" "EXTRACT|<null>"
pin  "2 over columns" "select id, extract(quarter from dt), extract(quarter from ts), extract(quarter from tz) from d order by id;" "ID EXTRACT EXTRACT EXTRACT|1 2 1 1|2 1 <null> <null>|3 4 1 4"
pin  "2 in WHERE" "select id from d where extract(quarter from dt) = 2;" "ID|1"
pin  "2 in GROUP BY" "select extract(quarter from dt) q, count(*) from d group by extract(quarter from dt) order by 1;" "Q COUNT|1 1|2 1|4 1"
pin  "2 in ORDER BY" "select id from d order by extract(quarter from dt), id;" "ID|2|1|3"
pin  "2 in an IN subquery" "select id from d where id in (select id from d where extract(quarter from dt) = 1) order by id;" "ID|2"

echo "--- 3. FIRST_DAY / LAST_DAY(OF <part> FROM d) - was -204 \"DATE\" / \"DT\""
pin  "3 the member: FIRST_DAY OF MONTH" "select first_day(of month from date '2024-05-17') from rdb\$database;" "FIRST_DAY|2024-05-01"
pin  "3 LAST_DAY OF MONTH, a leap February" "select last_day(of month from date '2024-02-10') from rdb\$database;" "LAST_DAY|2024-02-29"
pin  "3 OF QUARTER" "select first_day(of quarter from date '2024-08-17'), last_day(of quarter from date '2024-08-17') from rdb\$database;" "FIRST_DAY LAST_DAY|2024-07-01 2024-09-30"
pin  "3 OF WEEK: Sunday .. Saturday" "select first_day(of week from date '2024-05-17'), last_day(of week from date '2024-05-17') from rdb\$database;" "FIRST_DAY LAST_DAY|2024-05-12 2024-05-18"
pin  "3 OF WEEK from a Sunday" "select first_day(of week from date '2024-05-19'), last_day(of week from date '2024-05-19') from rdb\$database;" "FIRST_DAY LAST_DAY|2024-05-19 2024-05-25"
pin  "3 OF YEAR" "select first_day(of year from date '2024-05-17'), last_day(of year from date '2024-05-17') from rdb\$database;" "FIRST_DAY LAST_DAY|2024-01-01 2024-12-31"
pin  "3 a TIMESTAMP keeps its time" "select last_day(of month from timestamp '2024-02-10 13:14:15.1234') from rdb\$database;" "LAST_DAY|2024-02-29 13:14:15.1234"
pin  "3 described DATE / TIMESTAMP" "$SQLDA select first_day(of month from dt), last_day(of year from ts) from d where id = 1;" "INPUT message field count: 0|OUTPUT message field count: 2|01: sqltype: 570 SQL DATE Nullable scale: 0 subtype: 0 len: 4|: name: FIRST_DAY alias: FIRST_DAY|: table: schema: owner:|02: sqltype: 510 TIMESTAMP Nullable scale: 0 subtype: 0 len: 8|: name: LAST_DAY alias: LAST_DAY|: table: schema: owner:|FIRST_DAY LAST_DAY|2024-05-01 2024-12-31 13:14:15.1234"
pin  "3 a zoned TIMESTAMP keeps its zone" "select last_day(of month from timestamp '2024-02-10 13:14:15 Europe/Paris') from rdb\$database;" "LAST_DAY|2024-02-29 13:14:15.0000 Europe/Paris"
pin  "3 over zoned columns" "select id, first_day(of year from tz), last_day(of week from tz) from d order by id;" "ID FIRST_DAY LAST_DAY|1 2024-01-01 13:14:15.0000 Europe/Paris 2024-02-10 13:14:15.0000 Europe/Paris|2 <null> <null>|3 2023-01-01 23:30:00.0000 America/New_York 2024-01-06 23:30:00.0000 America/New_York"
pin  "3 a TIME raises at fetch" "select first_day(of month from time '10:00:00') from rdb\$database;" "FIRST_DAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Expected DATE/TIMESTAMP value in FIRST_DAY"
pin  "3 a string raises at fetch" "select first_day(of month from '2024-05-17') from rdb\$database;" "FIRST_DAY|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Expected DATE/TIMESTAMP value in FIRST_DAY"
pin  "3 a typed NULL" "select first_day(of month from cast(null as date)) from rdb\$database;" "FIRST_DAY|<null>"
pin  "3 below 0001-01-01 is 22008" "select first_day(of week from date '0001-01-01') from rdb\$database;" "FIRST_DAY|Statement failed, SQLSTATE = 22008|value exceeds the range for valid timestamps"
pin  "3 past 9999-12-31 is 22008" "select last_day(of week from date '9999-12-31') from rdb\$database;" "LAST_DAY|Statement failed, SQLSTATE = 22008|value exceeds the range for valid timestamps"
pin  "3 over columns" "select id, first_day(of month from dt), last_day(of quarter from dt), first_day(of week from ts) from d order by id;" "ID FIRST_DAY LAST_DAY FIRST_DAY|1 2024-05-01 2024-06-30 2024-02-04 13:14:15.1234|2 2024-02-01 2024-03-31 <null>|3 2023-12-01 2023-12-31 2023-01-01 00:00:00.0000"
pin  "3 in WHERE" "select id from d where first_day(of year from dt) = date '2024-01-01' order by id;" "ID|1|2"
pin  "3 in GROUP BY position" "select first_day(of month from dt), count(*) from d group by 1 order by 1;" "FIRST_DAY COUNT|2023-12-01 1|2024-02-01 1|2024-05-01 1"
pin  "3 in ORDER BY" "select id, last_day(of month from dt) from d order by extract(quarter from dt), id;" "ID LAST_DAY|2 2024-02-29|1 2024-05-31|3 2023-12-31"
pin  "3 a view over all three" "select * from vo order by id;" "ID O Q F|1 Zello world 2 2024-05-01|2 <null> 1 2024-02-01|3 Zbc 4 2023-12-01"
pin  "3 arithmetic over two" "select last_day(of month from dt) - first_day(of month from dt) from d order by id;" "SUBTRACT|30|28|30"

echo "--- 4. NTH_VALUE(v, n) FROM FIRST | FROM LAST - was -204 \"LAST\" / \"FIRST\""
pin  "4 the member: FROM LAST" "select id, nth_value(val, 2) from last over (order by id) from w where g = 1;" "ID NTH_VALUE|1 <null>|2 10|3 20"
pin  "4 the member: FROM FIRST" "select id, nth_value(val, 2) from first over (order by id) from w where g = 1;" "ID NTH_VALUE|1 <null>|2 20|3 20"
pin  "4 FROM LAST by partition" "select id, nth_value(val, 2) from last over (partition by g order by id) from w order by id;" "ID NTH_VALUE|1 <null>|2 10|3 20|4 <null>|5 40|6 <null>"
pin  "4 FROM LAST over the whole partition" "select id, nth_value(val, 1) from last over (partition by g order by id rows between unbounded preceding and unbounded following) from w order by id;" "ID NTH_VALUE|1 30|2 30|3 30|4 60|5 60|6 60"
pin  "4 FROM FIRST over a sliding frame" "select id, nth_value(val, 2) from first over (partition by g order by id rows between current row and 2 following) from w order by id;" "ID NTH_VALUE|1 20|2 30|3 <null>|4 <null>|5 60|6 <null>"
pin  "4 FROM LAST over a sliding frame" "select id, nth_value(val, 2) from last over (order by id rows between 1 preceding and 1 following) from w order by id;" "ID NTH_VALUE|1 10|2 20|3 30|4 40|5 <null>|6 <null>"
pin  "4 spacing and case, an alias" "select id, nth_value(val, 2) FROM   LAST   over (order by id) as nv from w order by id;" "ID NV|1 <null>|2 10|3 20|4 30|5 40|6 <null>"
pin  "4 inside arithmetic" "select id, nth_value(val, 2) from last over (order by id) + 1 from w order by id;" "ID ADD|1 <null>|2 11|3 21|4 31|5 41|6 <null>"
pin  "4 inside COALESCE" "select id, coalesce(nth_value(val, 2) from last over (order by id), -1) from w order by id;" "ID COALESCE|1 -1|2 10|3 20|4 30|5 40|6 -1"
pin  "4 both directions in one list" "select id, nth_value(val, 2) from last over (order by id), nth_value(val, 2) from first over (order by id) from w;" "ID NTH_VALUE NTH_VALUE|1 <null> <null>|2 10 20|3 20 20|4 30 20|5 40 20|6 <null> 20"
pin  "4 in a derived table" "select * from (select id, nth_value(val, 2) from last over (order by id) nv from w) where nv is not null order by id;" "ID NV|2 10|3 20|4 30|5 40"
pin  "4 the plain form is FROM FIRST" "select id, nth_value(val, 2) over (order by id) from w;" "ID NTH_VALUE|1 <null>|2 20|3 20|4 20|5 20|6 20"

echo "--- 5. IS [NOT] DISTINCT FROM - in a select list, a WHERE, a PSQL body"
pin  "5 a select item" "select id, s is distinct from 'abc' from d order by id;" "ID BOOL|1 <true>|2 <true>|3 <false>"
pin  "5 WHERE IS NOT DISTINCT" "select id from d where s is not distinct from 'abc';" "ID|3"
pin  "5 WHERE IS DISTINCT FROM NULL" "select id from d where s is distinct from null order by id;" "ID|1|3"
pin  "5 two of them, OR" "select id from w where (val is not distinct from null) or (id is distinct from id);" "ID|5"
pin  "5 a count" "select count(*) from w where val is distinct from 20;" "COUNT|5"
pin  "5 IIF over it" "select iif(1 is distinct from 2, 'y', 'n') from rdb\$database;" "CASE|y"
pin  "5 the PSQL member: IF (literals)" "$(eb 'execute block returns (r integer) as begin if (1 is distinct from 2) then r = 1; else r = 0; suspend; end')" "R|1"
pin  "5 IF over a NULL variable" "$(eb 'execute block returns (r integer) as declare x integer; begin x = null; if (x is distinct from 2) then r = 1; else r = 0; suspend; end')" "R|1"
pin  "5 IF IS NOT DISTINCT" "$(eb 'execute block returns (r integer) as declare x integer; begin x = 2; if (x is not distinct from 2) then r = 1; else r = 0; suspend; end')" "R|1"
pin  "5 NOT over IS DISTINCT" "$(eb 'execute block returns (r integer) as declare x integer; begin x = 2; if (not (x is distinct from 2)) then r = 1; else r = 0; suspend; end')" "R|1"
pin  "5 IIF IS NOT DISTINCT FROM NULL (was -204 \"NULL\")" "$(eb 'execute block returns (r integer) as declare x integer; begin x = null; r = iif(x is not distinct from null, 7, 8); suspend; end')" "R|7"
pin  "5 IIF over literals" "$(eb 'execute block returns (r integer) as begin r = iif(1 is distinct from 2, 1, 0); suspend; end')" "R|1"
pin  "5 WHILE" "$(eb 'execute block returns (r integer) as declare x integer = 0; begin while (x is distinct from 3) do x = x + 1; r = x; suspend; end')" "R|3"
pin  "5 CASE WHEN" "$(eb 'execute block returns (r integer) as declare x integer; begin x = 5; r = case when x is distinct from 5 then 1 else 2 end; suspend; end')" "R|2"
pin  "5 strings (was -204 \"'B'\")" "$(eb "execute block returns (r integer) as begin if ('a' is distinct from 'b') then r = 1; else r = 2; suspend; end")" "R|1"
refused "5 booleans: the compiler has no TRUE / FALSE literal (was -204 \"FALSE\")" "$(eb 'execute block returns (r integer) as begin if (true is distinct from false) then r = 1; else r = 2; suspend; end')" "R|1"

echo "--- 6. a FROM that is text, a comment, a name - and the siblings that always answered"
pin  "6 SUBSTRING FROM FOR" "select substring(s from 1 for 5) from d order by id;" "SUBSTRING|hello|<null>|abc"
pin  "6 TRIM LEADING FROM" "select trim(leading 'h' from s) from d order by id;" "TRIM|ello world|<null>|abc"
pin  "6 EXTRACT YEAR / MONTH" "select extract(year from dt), extract(month from dt) from d order by id;" "EXTRACT EXTRACT|2024 5|2024 2|2023 12"
pin  "6 POSITION IN" "select position('o' in s) from d order by id;" "POSITION|5|<null>|0"
pin  "6 DATEDIFF FROM TO" "select datediff(day from dt to date '2024-12-31') from d order by id;" "DATEDIFF|228|325|366"
pin  "6 a literal 'from'" "select 'from' from rdb\$database;" "CONSTANT|from"
pin  "6 a literal 'from x'" "select 'from x', s from d where id = 3;" "CONSTANT S|from x abc"
pin  "6 a q-literal holding FROM" "select q'{from x}' from rdb\$database;" "CONSTANT|from x"
pin  "6 a line comment holding FROM" "select 1 -- from nosuch
from rdb\$database;" "CONSTANT|1"
pin  "6 a block comment holding FROM" "select 1 /* from nosuch */ from rdb\$database;" "CONSTANT|1"
pin  "6 a column alias \"FROM\"" "select 1 as \"FROM\" from rdb\$database;" "FROM|1"
pin  "6 a table and a column named FROM" "select \"FROM\" from \"FROM\";" "FROM|x"
pin  "6 ...qualified, in WHERE" "select f.\"FROM\" from \"FROM\" f where f.\"FROM\" = 'x';" "FROM|x"
pin  "6 a real unknown table after a function FROM" "select substring(s from 1 for 1) from nosuch;" "Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-\"NOSUCH\"|-At line 1, column 39"
pin  "6 ...after an OVERLAY" "select overlay('a' placing 'b' from 1) from nosuch;" "Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-\"NOSUCH\"|-At line 1, column 45"
pin  "6 ...after IS DISTINCT FROM" "select 1 is distinct from 2 from nosuch;" "Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-\"NOSUCH\"|-At line 1, column 34"

echo "--- 7. DML carrying them"
pin  "7 UPDATE SET OVERLAY WHERE QUARTER" "update d set s = overlay(s placing 'Z' from 1 for 1) where extract(quarter from dt) = 2; select id, s from d order by id; rollback;" "ID S|1 Zello world|2 <null>|3 abc"
pin  "7 DELETE WHERE FIRST_DAY" "delete from d where first_day(of year from dt) = date '2023-01-01'; select id from d order by id; rollback;" "ID|1|2"
pin  "7 INSERT SELECT OVERLAY" "insert into d (id, s) select 9, overlay('abc' placing 'q' from 2) from rdb\$database; select id, s from d where id = 9; rollback;" "ID S|9 aqc"
pin  "7 UPDATE WHERE IS DISTINCT" "update d set n = extract(quarter from dt) where s is distinct from 'abc'; select id, n from d order by id; rollback;" "ID N|1 2|2 1|3 5"
pin  "7 INSERT VALUES LAST_DAY" "insert into d (id, dt) values (10, last_day(of quarter from date '2024-08-08')); select id, dt from d where id = 10; rollback;" "ID DT|10 2024-09-30"
pin  "7 MERGE UPDATE OVERLAY" "merge into d t using (select 3 id from rdb\$database) x on t.id = x.id when matched then update set s = overlay(t.s placing 'M' from 1); select id, s from d where id = 3; rollback;" "ID S|3 Mbc"
pin  "7 RETURNING OVERLAY" "update d set s = 'k' where id is not distinct from 3 returning overlay(s placing 'R' from 1); rollback;" "OVERLAY|R"
pin  "7 RETURNING FIRST_DAY" "delete from d where id = 1 returning first_day(of month from dt); rollback;" "FIRST_DAY|2024-05-01"

echo "--- 7b. A VIEW over IS [NOT] DISTINCT FROM, compiled here (blr_equiv; it refused)"
pin  "7b CREATE VIEW ... IS DISTINCT FROM" "create view vd1 as select id from w where val is distinct from 20; commit; select id from vd1 order by id; select octet_length(rdb\$view_blr) from rdb\$relations where rdb\$relation_name = 'VD1';" "ID|1|3|4|5|6|OCTET_LENGTH|25"
pin  "7b CREATE VIEW ... IS NOT DISTINCT FROM NULL" "create view vd2 as select id from w where val is not distinct from null; commit; select id from vd2 order by id; select octet_length(rdb\$view_blr) from rdb\$relations where rdb\$relation_name = 'VD2';" "ID|5|OCTET_LENGTH|18"
pin  "7b CREATE VIEW ... NOT (IS DISTINCT FROM): the NOT cancels" "create view vd3 as select id from w where not (val is distinct from 20); commit; select id from vd3 order by id; select octet_length(rdb\$view_blr) from rdb\$relations where rdb\$relation_name = 'VD3';" "ID|2|OCTET_LENGTH|24"

echo "--- 8. RECORDED: the engine answers, this server refuses"
refused "8 a VIEW whose select item is IS NOT DISTINCT (the compiler has no boolean item)" "create view vd4 as select id, val is not distinct from 20 b from w; commit; select count(*) from rdb\$relations where rdb\$relation_name = 'VD4';" "COUNT|1"
refused "8 a VIEW over OVERLAY (the compiler knows no OVERLAY)" "create view vd5 as select overlay(s placing 'x' from 1) o from d; commit; select count(*) from rdb\$relations where rdb\$relation_name = 'VD5';" "COUNT|1"
refused "8 LIST cast" "select cast(list(v) as varchar(50)) from t;" "CAST|b,a"
refused "8 LIST concatenated" "select list(v) || '!' from t;" "CONCATENATION|0:2|CONCATENATION:|b,a!"
refused "8 LIST measured" "select char_length(list(v)) from t;" "CHAR_LENGTH|3"
refused "8 SUBSTRING over LIST (was -204 \"1\")" "select substring(list(v) from 1 for 3) from t;" "SUBSTRING|0:2|SUBSTRING:|b,a"
refused "8 OVERLAY in a PSQL assignment" "$(eb "execute block returns (r varchar(10)) as begin r = overlay('abcdef' placing 'Z' from 2 for 3); suspend; end")" "R|aZef"
refused "8 EXTRACT QUARTER in a PSQL assignment" "$(eb "execute block returns (r integer) as begin r = extract(quarter from date '2024-11-01'); suspend; end")" "R|4"
refused "8 FIRST_DAY in a PSQL assignment (was -204 \"DATE\")" "$(eb "execute block returns (r date) as begin r = first_day(of month from date '2024-11-11'); suspend; end")" "R|2024-11-01"
refused "8 ...as EXTRACT(YEAR) is (the compiler's boundary)" "$(eb "execute block returns (r integer) as begin r = extract(year from date '2024-11-01'); suspend; end")" "R|2024"
refused "8 OVERLAY over two sets" "select overlay(u placing w from 1) from u8;" "OVERLAY|def"
refused "8 an unordered NTH_VALUE FROM LAST" "select id, nth_value(val, 1) from last over (partition by g) from w order by id;" "ID NTH_VALUE|1 30|2 30|3 30|4 <null>|5 <null>|6 <null>"
err_differs "8 DATEADD QUARTER" "select dateadd(1 quarter to date '2024-01-31') from rdb\$database;" "DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Invalid part QUARTER to be added to a DATE/TIME/TIMESTAMP value in DATEADD"
err_differs "8 DATEDIFF QUARTER" "select datediff(quarter, date '2024-01-01', date '2024-12-01') from rdb\$database;" "DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Invalid part QUARTER to express the difference between two DATE/TIME/TIMESTAMP values in DATEDIFF"
err_differs "8 an unknown EXTRACT part" "select extract(bogus from dt) from d;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 16|-bogus"
err_differs "8 FIRST_DAY OF DAY" "select first_day(of day from date '2024-05-17') from rdb\$database;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 21|-day"
err_differs "8 FIRST_VALUE FROM LAST (was -204 \"LAST\")" "select id, first_value(val) from last over (order by id) from w;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 29|-from"
err_differs "8 NTH_VALUE FROM MIDDLE (was -204 \"MIDDLE\")" "select id, nth_value(val, 2) from middle over (order by id) from w;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 35|-middle"
err_differs "8 an unknown function with a FROM" "select foo(1 from 2) from d;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 14|-from"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-fromloc-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 140 ]; then echo "FAIL only $ran checks ran (floor 140)"; fail=1; fi
exit $fail
