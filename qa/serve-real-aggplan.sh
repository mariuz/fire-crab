#!/bin/bash
# THE AGGREGATE / WINDOW PLANNER'S SHAPES, composed as the engine composes
# them - every cell measured on engine 2182 (2026-09-26) and pinned:
#
#   - a WINDOW over a GROUP BY, a HAVING, an implicit group, a JOIN, a
#     derived table, a CTE or a view; under DISTINCT, FIRST/SKIP, ROWS
#     and OFFSET/FETCH; in the statement's ORDER BY; a named window
#     REFINED by ORDER BY or a frame; a bare window beside a window
#     inside an expression. All refused on fc/integ b0b662f; the planner
#     now rewrites a windowed select into the three levels the engine
#     composes ([rewrite_windowed_select]: the query without its
#     windows, the windows over it, the names / modifiers / ORDER BY
#     over that).
#   - DELIVERY ORDER without a statement ORDER BY: the LAST SORTED
#     WINDOW's order, an `OVER ()` neither sorting nor resetting, ties
#     by the previous windows' values then the referenced base fields
#     (WindowedStream.cpp's chain; [compute_windows]).
#   - HAVING without GROUP BY over a constant list; ORDER BY an
#     aggregate on the implicit group; a FILTER inside an expression;
#     SUM/AVG/MIN/MAX(DISTINCT x); SUM/AVG/MIN/MAX/COUNT over the untyped
#     NULL literal (a CHAR(1) NONE, measured); STDDEV/VAR as windows.
#   - FRAME BOUNDS: UNBOUNDED FOLLOWING as bound 1, UNBOUNDED PRECEDING
#     as bound 2 and any FOLLOWING in the shorthand are the PARSER's
#     -104 Token unknown at that keyword (line/column pinned); FOLLOWING
#     then PRECEDING/CURRENT ROW, and CURRENT ROW then PRECEDING, are
#     the bare dsql_window_incompat_frames; a NULL or string offset the
#     bare dsql_window_frame_value_inv_type; a NEGATIVE offset raises at
#     EXECUTE, over an empty input too. fc/integ ANSWERED the first four
#     shapes (rows or NULLs) where the engine raises. The same rule in a
#     NAMED window (WINDOW W AS (...)) and inside DML - an UPDATE's or
#     DELETE's subquery, an INSERT's source - where a folded frame had
#     MODIFIED rows (section 15).
#   - A GROUP BY name is a select-list ALIAS first, then a column, even
#     when the alias shadows a base column's name: `SELECT VAL ID,
#     COUNT(*) FROM W GROUP BY VAL, ID` groups by VAL twice over (four
#     groups); a bare field item of the alias's name beside it is the
#     42702 "Ambiguous field name between a field and an alias". HAVING,
#     WHERE, an aggregate's argument and a window's own ORDER BY /
#     PARTITION BY name the COLUMN; a QUALIFIED key is the column. The
#     group planner grouped five ways, and every windowed form of the
#     shape answered that grouping through the rewrite's L1 (section 14).
#   - THE SORT RECORD (section 16): the statement ORDER BY above a
#     window breaks its ties by the window streams' record (the select
#     list's fields in written order, a window's values, a PARTITION BY
#     stream's extra slot), and every sort compares that record as the
#     engine lays it out - NULL flag bytes, then aligned values, as
#     little-endian words - so a NULL VARCHAR whose length shares word 0
#     with the flags LEADS its ties. fc/integ 6ec54c8 sorted the windows'
#     delivery order stably (a different row set under OFFSET/FETCH and
#     FIRST) and numbered a NULL group or a LEFT JOIN's NULL key after
#     its peers. VAR/STDDEV over a derived or rewritten column holding a
#     computed scaled INT128 (SUM of a NUMERIC(18,2), X + 0 over a
#     NUMERIC(38,4)) answered the DECFLOAT 0E-6176. A string literal
#     holding a parenthesis or a comma, a duplicate named window (-204)
#     and a frame offset past INTEGER (22003 at execute) - refused or
#     answered on fc/integ.
#   - THE RELATION UNDER A DERIVED TABLE (section 17): a window over a
#     derived table, CTE or view that reads one relation through plain
#     levels sorts that relation's record - every field the statement
#     references, the derived table's own WHERE among them, in the
#     relation's field order; the ORDER BY over a WINDOWED derived table
#     ties by that table's window streams; a RANGE offset past INTEGER
#     answers (only a ROWS offset is an INTEGER row count); a grouped
#     item that IS a GROUP BY expression is one field of the aggregate,
#     and an ORDER BY key lifted beside an item it restores leaves the
#     record. Red on fc/aggplan-r3 6f1adf6 (wrong ties, a spurious
#     22003, a wrong FIRST row set, a refusal); a FIRST, a DISTINCT
#     or a view inside the derived table reads the same relation.
#
# RECORDED, not fixed (section 12 and the refused/differs cells): CREATE
# VIEW over an aggregate, a GROUP BY or a window; LAG/LEAD/NTH_VALUE with
# a NULL or non-constant offset; RANGE offsets over a NUMERIC or DATE
# key; a fractional or column frame offset; a frame with no ORDER BY;
# LIST and PERCENTILE_CONT as windows; MIN and COUNT(DISTINCT) over a
# BLOB; CREATE VIEW ... WITH CHECK OPTION; DISTINCT in an ordered window (the engine's 0A000, a generic
# refusal here); a bare column under a lone HAVING or in the ORDER BY of
# an implicit group (the engine's specific -104, a generic refusal here);
# a qualified GROUP BY / ORDER BY key whose bare name a select-list alias
# shadows (the column on the engine - answered or refused with -104 - a
# generic refusal here); an illegal frame inside EXECUTE BLOCK.
#
# Usage: qa/serve-real-aggplan.sh [port]   (default 6010)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-6010}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/aggplan-eng.fdb"; FC="$D/aggplan-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE W (ID INTEGER, GRP VARCHAR(5), VAL INTEGER, AMT NUMERIC(9,2), D DATE);
INSERT INTO W VALUES (1, 'A', 10, 1.10, DATE '2024-01-01');
INSERT INTO W VALUES (2, 'A', 20, 2.20, DATE '2024-01-20');
INSERT INTO W VALUES (3, 'B', 20, 3.30, DATE '2024-03-01');
INSERT INTO W VALUES (4, 'B', NULL, NULL, NULL);
INSERT INTO W VALUES (5, NULL, 5, 4.40, DATE '2024-04-01');
CREATE TABLE T (I INTEGER, N NUMERIC(10,2), V VARCHAR(20));
INSERT INTO T VALUES (10, 1.50, 'a');
INSERT INTO T VALUES (20, 2.25, 'b');
INSERT INTO T VALUES (20, 2.25, NULL);
CREATE TABLE E (ID INTEGER, GRP VARCHAR(5), VAL INTEGER);
CREATE TABLE T1 (ID INTEGER, N INTEGER, S VARCHAR(10));
INSERT INTO T1 VALUES (1, 5, 'a');
INSERT INTO T1 VALUES (2, 7, 'b');
CREATE TABLE TP (ID INTEGER, NAME VARCHAR(10));
INSERT INTO TP VALUES (1, 'p');
CREATE TABLE CS (BL BLOB SUB_TYPE TEXT);
INSERT INTO CS VALUES ('x');
INSERT INTO CS VALUES ('yy');
INSERT INTO CS VALUES (NULL);
INSERT INTO CS VALUES ('x');
CREATE VIEW VW (ID, GRP, VAL) AS SELECT ID, GRP, VAL FROM W;
CREATE TABLE RT (ID INTEGER, K INTEGER, S VARCHAR(10), V INTEGER);
INSERT INTO RT VALUES (1,1,'b',3); INSERT INTO RT VALUES (2,2,'a',1); INSERT INTO RT VALUES (3,1,'a',2); INSERT INTO RT VALUES (4,2,'c',3); INSERT INTO RT VALUES (5,1,NULL,1); INSERT INTO RT VALUES (6,NULL,'b',2); INSERT INTO RT VALUES (7,2,'b',NULL); INSERT INTO RT VALUES (8,1,'c',3); INSERT INTO RT VALUES (9,NULL,'a',1); INSERT INTO RT VALUES (10,2,'a',2);
CREATE TABLE RH (ID INTEGER, X NUMERIC(38,4), Z NUMERIC(18,2));
INSERT INTO RH VALUES (1,1.5,1.5); INSERT INTO RH VALUES (2,2.25,2.25); INSERT INTO RH VALUES (3,0,0);
CREATE TABLE RC (ID INTEGER, T VARCHAR(10), N NUMERIC(18,4), B BIGINT);
INSERT INTO RC VALUES (1,'x',1.5,9000000000000000000); INSERT INTO RC VALUES (2,'y',2.25,9000000000000000000); INSERT INTO RC VALUES (3,'x',NULL,1); INSERT INTO RC VALUES (4,'y',-1.125,-1); INSERT INTO RC VALUES (5,NULL,0,2);
CREATE TABLE RW (ID INTEGER, GRP VARCHAR(5), VAL INTEGER);
INSERT INTO RW VALUES (1,'A',10); INSERT INTO RW VALUES (2,'A',20); INSERT INTO RW VALUES (3,'B',20); INSERT INTO RW VALUES (4,'B',NULL); INSERT INTO RW VALUES (5,NULL,5); INSERT INTO RW VALUES (6,'C',10); INSERT INTO RW VALUES (7,'A',10);
CREATE TABLE RG (GRP VARCHAR(5), NAME VARCHAR(10));
INSERT INTO RG VALUES ('A','alpha'); INSERT INTO RG VALUES ('B','beta'); INSERT INTO RG VALUES ('D','delta');
CREATE TABLE RU (ID INTEGER, K INTEGER, K2 INTEGER, S VARCHAR(10), V INTEGER, B BIGINT);
INSERT INTO RU VALUES (1,1,1,'b',3,3); INSERT INTO RU VALUES (2,2,2,'a',1,5); INSERT INTO RU VALUES (3,1,NULL,'a',2,-7); INSERT INTO RU VALUES (4,2,1,'c',3,-1); INSERT INTO RU VALUES (5,1,2,NULL,1,NULL); INSERT INTO RU VALUES (6,NULL,2,'b',2,3); INSERT INTO RU VALUES (7,2,NULL,'b',NULL,-7); INSERT INTO RU VALUES (8,1,1,'c',3,0); INSERT INTO RU VALUES (9,NULL,NULL,'a',1,5); INSERT INTO RU VALUES (10,2,2,'ab',2,-1); INSERT INTO RU VALUES (11,1,1,'',1,3); INSERT INTO RU VALUES (12,2,NULL,'b',3,NULL);
CREATE VIEW RUV (ID, K, S, V) AS SELECT ID, K, S, V FROM RU;
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/aggplan-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/aggplan-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/aggplan-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-aggplan-$PORT.log" 2>&1 & srv=$!
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
# the describe: type, length, charset, nullability, name and table
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype\|name:\|table:' | sed 's/  */ /g;s/^ *//' | paste -sd'|'; }
# the ENGINE is pinned and this server must agree (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [${ev:0:70}]"; fi
}
# the same describe, pinned
dpin() { # <label> <select> <engine-describe>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ed" != "$3" ]; then echo "FAIL $1 - THE ENGINE DESCRIBES [$ed], not the pinned [$3]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [${ed:0:70}]"; fi
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
# both RAISE, with different vectors - recorded (a refusal where the
# engine has a specific error; never an answer)
differs() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" = "$ev" ]; then echo "FAIL $1 - the engine answers now [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - AN ANSWER where the engine raises"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server refuses generically)"; fi
}

echo "--- 1. WINDOWS OVER A GROUP BY, A HAVING, AN IMPLICIT GROUP"
pin  "1 rank over sum, grouped, ordered" "SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM W GROUP BY GRP ORDER BY GRP;" "GRP RANK|<null> 3|A 1|B 2"
pin  "1 ...bare: delivered in the window's order" "SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM W GROUP BY GRP;" "GRP RANK|A 1|B 2|<null> 3"
pin  "1 count(*) over () on a GROUP BY" "SELECT GRP, COUNT(*) OVER () FROM W GROUP BY GRP ORDER BY GRP;" "GRP COUNT|<null> 3|A 3|B 3"
pin  "1 count(*), row_number() over () - the implicit group" "SELECT COUNT(*), ROW_NUMBER() OVER () FROM W;" "COUNT ROW_NUMBER|5 1"
pin  "1 sum(val), count(*) over () implicit group" "SELECT SUM(VAL), COUNT(*) OVER () FROM W;" "SUM COUNT|55 1"
pin  "1 a window over a grouped HAVING" "SELECT GRP, SUM(VAL), RANK() OVER (ORDER BY SUM(VAL)) FROM W GROUP BY GRP HAVING COUNT(*) > 0;" "GRP SUM RANK|<null> 5 1|B 20 2|A 30 3"
pin  "1 window keyed by the grouped column" "SELECT GRP, SUM(VAL), ROW_NUMBER() OVER (ORDER BY GRP NULLS LAST) FROM W GROUP BY GRP;" "GRP SUM ROW_NUMBER|A 30 1|B 20 2|<null> 5 3"
pin  "1 partition by an aggregate" "SELECT GRP, COUNT(*) OVER (PARTITION BY COUNT(*)) FROM W GROUP BY GRP ORDER BY GRP;" "GRP COUNT|<null> 1|A 2|B 2"
pin  "1 over an EMPTY table, grouped" "SELECT GRP, RANK() OVER (ORDER BY SUM(VAL)) FROM E GROUP BY GRP;" ""
pin  "1 over an EMPTY table, implicit group" "SELECT COUNT(*), ROW_NUMBER() OVER () FROM E;" "COUNT ROW_NUMBER|0 1"
pin  "1 NULL sums rank last under DESC" "SELECT GRP, SUM(VAL), RANK() OVER (ORDER BY SUM(VAL) DESC NULLS LAST) FROM W GROUP BY GRP ORDER BY 3;" "GRP SUM RANK|A 30 1|B 20 2|<null> 5 3"
pin  "1 ties: two groups with equal sums share a RANK" "SELECT GRP, RANK() OVER (ORDER BY COUNT(*) DESC) FROM W GROUP BY GRP ORDER BY GRP;" "GRP RANK|<null> 3|A 1|B 1"
pin  "1 ...and DENSE_RANK / ROW_NUMBER over the same" "SELECT GRP, DENSE_RANK() OVER (ORDER BY COUNT(*) DESC), ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) FROM W GROUP BY GRP ORDER BY GRP;" "GRP DENSE_RANK ROW_NUMBER|<null> 2 3|A 1 1|B 1 2"
pin  "1 the shape inside a derived table" "SELECT R, GRP FROM (SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) R FROM W GROUP BY GRP) D ORDER BY R;" "R GRP|1 A|2 B|3 <null>"
pin  "1 ...inside a CTE" "WITH C AS (SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) R FROM W GROUP BY GRP) SELECT GRP, R FROM C ORDER BY R;" "GRP R|A 1|B 2|<null> 3"
pin  "1 ...over a VIEW" "SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM VW GROUP BY GRP ORDER BY GRP;" "GRP RANK|<null> 3|A 1|B 2"
pin  "1 window expression over an aggregate" "SELECT GRP, SUM(VAL) * 100 / SUM(SUM(VAL)) OVER () FROM W GROUP BY GRP ORDER BY GRP;" "GRP DIVIDE|<null> 9|A 54|B 36"
pin  "1 a WHERE under the group under the window" "SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM W WHERE VAL IS NOT NULL GROUP BY GRP ORDER BY GRP;" "GRP RANK|<null> 3|A 1|B 2"
dpin "1 describe: grouped column keeps its table, RANK is INT64" "SELECT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM W GROUP BY GRP;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 5 charset: 0 SYSTEM.NONE|: name: GRP alias: GRP|: table: W schema: PUBLIC owner: SYSDBA|02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: RANK alias: RANK|: table: schema: owner: "
dpin "1 describe: COUNT beside a window" "SELECT COUNT(*), ROW_NUMBER() OVER () FROM W;" "01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: COUNT alias: COUNT|: table: schema: owner: |02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: ROW_NUMBER alias: ROW_NUMBER|: table: schema: owner: "
dpin "1 describe: sum and window expression" "SELECT GRP, SUM(VAL), SUM(VAL) * 100 / SUM(SUM(VAL)) OVER () FROM W GROUP BY GRP;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 5 charset: 0 SYSTEM.NONE|: name: GRP alias: GRP|: table: W schema: PUBLIC owner: SYSDBA|02: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|: name: SUM alias: SUM|: table: schema: owner: |03: sqltype: 32752 INT128 Nullable scale: 0 subtype: 0 len: 16|: name: DIVIDE alias: DIVIDE|: table: schema: owner: "

echo "--- 2. HAVING WITHOUT GROUP BY; ORDER BY AN AGGREGATE ON THE IMPLICIT GROUP"
pin  "2 HAVING count(*) > 1 over a constant list" "SELECT 1 FROM W HAVING COUNT(*) > 1;" "CONSTANT|1"
pin  "2 ...condition false: no row" "SELECT 1 FROM W HAVING COUNT(*) > 100;" ""
pin  "2 ...a string constant, empty table" "SELECT 'x' FROM E HAVING COUNT(*) = 0;" "CONSTANT|x"
pin  "2 ...inside EXISTS" "SELECT EXISTS(SELECT 1 FROM W HAVING COUNT(*) > 1) FROM RDB\$DATABASE;" "BOOL|<true>"
pin  "2 ...HAVING MAX(VAL) IS NULL" "SELECT 1 FROM W HAVING MAX(VAL) IS NULL;" ""
pin  "2 ...constant beside an aggregate" "SELECT 1, COUNT(*) FROM W HAVING COUNT(*) > 1;" "CONSTANT COUNT|1 5"
pin  "2 ...with a WHERE" "SELECT 1 FROM W WHERE VAL > 100 HAVING COUNT(*) > 0;" ""
pin  "2 ORDER BY SUM on the implicit group" "SELECT COUNT(*) FROM W ORDER BY SUM(ID);" "COUNT|5"
pin  "2 ...two keys" "SELECT COUNT(*) FROM W ORDER BY SUM(ID) DESC, MAX(VAL);" "COUNT|5"
pin  "2 ...ORDER BY the aggregate itself" "SELECT COUNT(*) FROM W ORDER BY COUNT(*);" "COUNT|5"
pin  "2 ...MAX ordered by MIN" "SELECT MAX(VAL) FROM W ORDER BY MIN(VAL);" "MAX|20"
pin  "2 ...by alias" "SELECT COUNT(*) C FROM W ORDER BY C;" "C|5"
pin  "2 ...by ordinal" "SELECT COUNT(*) FROM W ORDER BY 1;" "COUNT|5"
pin  "2 ...with HAVING too" "SELECT COUNT(*) FROM W HAVING COUNT(*) > 1 ORDER BY SUM(ID);" "COUNT|5"
pin  "2 ...over an empty table" "SELECT COUNT(*) FROM E ORDER BY SUM(ID);" "COUNT|0"
dpin "2 describe: the constant under HAVING" "SELECT 1 FROM W HAVING COUNT(*) > 1;" "01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4|: name: CONSTANT alias: CONSTANT|: table: schema: owner: "
dpin "2 describe: COUNT ordered by SUM" "SELECT COUNT(*) FROM W ORDER BY SUM(ID);" "01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: COUNT alias: COUNT|: table: schema: owner: "
differs "2 RECORDED a bare column under HAVING alone (engine: invalid expression)" "SELECT ID FROM W HAVING COUNT(*) > 1;"
differs "2 RECORDED ORDER BY a bare column on the implicit group" "SELECT COUNT(*) FROM W ORDER BY ID;"

echo "--- 3. A BARE WINDOW BESIDE A WINDOW INSIDE AN EXPRESSION"
pin  "3 bare window first, expression second" "SELECT ROW_NUMBER() OVER (ORDER BY ID), ROW_NUMBER() OVER (ORDER BY ID) + 1 FROM W ORDER BY 1;" "ROW_NUMBER ADD|1 2|2 3|3 4|4 5|5 6"
pin  "3 ...aliased" "SELECT ROW_NUMBER() OVER (ORDER BY ID) X, ROW_NUMBER() OVER (ORDER BY ID) + 1 Y FROM W ORDER BY X;" "X Y|1 2|2 3|3 4|4 5|5 6"
pin  "3 ...three items, mixed" "SELECT ID, COUNT(*) OVER () C, COALESCE(SUM(VAL) OVER (), 0) + ROW_NUMBER() OVER (ORDER BY ID) S FROM W ORDER BY ID;" "ID C S|1 5 56|2 5 57|3 5 58|4 5 59|5 5 60"
pin  "3 ...over an empty table" "SELECT ROW_NUMBER() OVER (ORDER BY ID), ROW_NUMBER() OVER (ORDER BY ID) + 1 FROM E;" ""
dpin "3 describe: ROW_NUMBER then ADD" "SELECT ROW_NUMBER() OVER (ORDER BY ID), ROW_NUMBER() OVER (ORDER BY ID) + 1 FROM W;" "01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: ROW_NUMBER alias: ROW_NUMBER|: table: schema: owner: |02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: ADD alias: ADD|: table: schema: owner: "

echo "--- 4. A FILTER INSIDE AN EXPRESSION"
pin  "4 SUM FILTER + 0" "SELECT SUM(VAL) FILTER (WHERE GRP = 'A') + 0 FROM W;" "ADD|30"
pin  "4 COALESCE(MAX FILTER, -1) - no row matches" "SELECT COALESCE(MAX(VAL) FILTER (WHERE GRP = 'Z'), -1) FROM W;" "COALESCE|-1"
pin  "4 two filtered sums added" "SELECT SUM(VAL) FILTER (WHERE GRP = 'A') + SUM(VAL) FILTER (WHERE GRP = 'B') FROM W;" "ADD|50"
pin  "4 grouped, times two" "SELECT GRP, COUNT(*) FILTER (WHERE VAL > 10) * 2 FROM W GROUP BY GRP ORDER BY GRP;" "GRP MULTIPLY|<null> 0|A 2|B 2"
pin  "4 filtered beside plain in one expression" "SELECT COUNT(*) FILTER (WHERE VAL > 10) + COUNT(*) FROM W;" "ADD|7"
pin  "4 over an empty table" "SELECT COALESCE(SUM(VAL) FILTER (WHERE GRP = 'A'), 0) FROM E;" "COALESCE|0"
pin  "4 COUNT(DISTINCT) FILTER in an expression" "SELECT COUNT(DISTINCT VAL) FILTER (WHERE GRP IS NOT NULL) * 10 FROM W;" "MULTIPLY|20"
pin  "4 in a derived table" "SELECT X FROM (SELECT SUM(VAL) FILTER (WHERE GRP = 'A') + 0 X FROM W) D;" "X|30"
dpin "4 describe: SUM FILTER + 0 is ADD INT64" "SELECT SUM(VAL) FILTER (WHERE GRP = 'A') + 0 FROM W;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|: name: ADD alias: ADD|: table: schema: owner: "
dpin "4 describe: COALESCE(MAX FILTER) keeps LONG" "SELECT COALESCE(MAX(VAL) FILTER (WHERE GRP = 'Z'), -1) FROM W;" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: COALESCE alias: COALESCE|: table: schema: owner: "

echo "--- 5. FIRST / SKIP / ROWS / OFFSET-FETCH OVER AGGREGATES, GROUPS AND WINDOWS"
pin  "5 FIRST 1 COUNT(*)" "SELECT FIRST 1 COUNT(*) FROM W;" "COUNT|5"
pin  "5 FIRST 2 grouped" "SELECT FIRST 2 GRP FROM W GROUP BY GRP ORDER BY GRP;" "GRP|<null>|A"
pin  "5 grouped ROWS 1" "SELECT GRP FROM W GROUP BY GRP ORDER BY GRP ROWS 1;" "GRP|<null>"
pin  "5 grouped FETCH FIRST" "SELECT GRP FROM W GROUP BY GRP ORDER BY GRP FETCH FIRST 1 ROW ONLY;" "GRP|<null>"
pin  "5 COUNT(*) ROWS 1" "SELECT COUNT(*) FROM T1 ROWS 1;" "COUNT|2"
pin  "5 FIRST 2 with a window, ordered" "SELECT FIRST 2 ID, ROW_NUMBER() OVER (ORDER BY ID) FROM W ORDER BY ID;" "ID ROW_NUMBER|1 1|2 2"
pin  "5 FIRST 3 window, no ORDER BY: the window's order" "SELECT FIRST 3 ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W;" "ROW_NUMBER|1|2|3"
pin  "5 SKIP 1 under a window" "SELECT SKIP 1 ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W;" "ID ROW_NUMBER|4 2|3 3|2 4|1 5"
pin  "5 window ROWS 2" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W ROWS 2;" "ID ROW_NUMBER|5 1|4 2"
pin  "5 window OFFSET/FETCH" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W OFFSET 1 ROW FETCH NEXT 2 ROWS ONLY;" "ID ROW_NUMBER|4 2|3 3"
pin  "5 FIRST 1 over a grouped window" "SELECT FIRST 1 GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM W GROUP BY GRP;" "GRP RANK|A 1"
pin  "5 SKIP 1 over a grouped window" "SELECT SKIP 1 GRP, COUNT(*) OVER () FROM W GROUP BY GRP;" "GRP COUNT|A 3|B 3"
pin  "5 FIRST over an empty windowed table" "SELECT FIRST 2 ID, ROW_NUMBER() OVER (ORDER BY ID) FROM E;" ""

echo "--- 6. NAMED-WINDOW REFINEMENT, ORDER BY A WINDOW, DISTINCT"
pin  "6 named window refined by ORDER BY" "SELECT ID, RANK() OVER (WIN ORDER BY VAL) FROM W WINDOW WIN AS (PARTITION BY GRP) ORDER BY ID;" "ID RANK|1 1|2 2|3 2|4 1|5 1"
pin  "6 ...bare: partition order, val within" "SELECT ID, RANK() OVER (WIN ORDER BY VAL) FROM W WINDOW WIN AS (PARTITION BY GRP);" "ID RANK|5 1|1 1|2 2|4 1|3 2"
pin  "6 ...refined by a frame" "SELECT ID, SUM(VAL) OVER (WIN ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM W WINDOW WIN AS (ORDER BY ID) ORDER BY ID;" "ID SUM|1 10|2 30|3 40|4 20|5 5"
pin  "6 ...the plain named form beside it" "SELECT ID, COUNT(*) OVER WIN, RANK() OVER (WIN ORDER BY VAL) FROM W WINDOW WIN AS (PARTITION BY GRP) ORDER BY ID;" "ID COUNT RANK|1 2 1|2 2 2|3 2 2|4 2 1|5 1 1"
pin  "6 ORDER BY a window function" "SELECT ID FROM W ORDER BY ROW_NUMBER() OVER (ORDER BY ID DESC);" "ID|5|4|3|2|1"
pin  "6 ...ORDER BY a window with ties, then ID" "SELECT ID FROM W ORDER BY ROW_NUMBER() OVER (ORDER BY VAL DESC), ID;" "ID|2|3|1|5|4"
pin  "6 ...ORDER BY a partitioned sum DESC" "SELECT ID, VAL FROM W ORDER BY SUM(VAL) OVER (PARTITION BY GRP) DESC, ID;" "ID VAL|1 10|2 20|3 20|4 <null>|5 5"
pin  "6 ...ORDER BY count(*) over ()" "SELECT ID FROM W ORDER BY COUNT(*) OVER () DESC, ID DESC;" "ID|5|4|3|2|1"
pin  "6 DISTINCT count over partition" "SELECT DISTINCT COUNT(*) OVER (PARTITION BY GRP) FROM W ORDER BY 1;" "COUNT|1|2"
pin  "6 DISTINCT COUNT(*) grouped" "SELECT DISTINCT COUNT(*) FROM W GROUP BY GRP ORDER BY 1;" "COUNT|1|2"
pin  "6 DISTINCT SUM implicit group" "SELECT DISTINCT SUM(VAL) FROM W;" "SUM|55"
pin  "6 DISTINCT grouped window" "SELECT DISTINCT GRP, RANK() OVER (ORDER BY SUM(VAL) DESC) FROM W GROUP BY GRP ORDER BY 2;" "GRP RANK|A 1|B 2|<null> 3"
pin  "6 DISTINCT window over an empty table" "SELECT DISTINCT COUNT(*) OVER (PARTITION BY GRP) FROM E;" ""
dpin "6 describe: refined named window" "SELECT ID, RANK() OVER (WIN ORDER BY VAL) FROM W WINDOW WIN AS (PARTITION BY GRP);" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: ID alias: ID|: table: W schema: PUBLIC owner: SYSDBA|02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: RANK alias: RANK|: table: schema: owner: "
dpin "6 describe: DISTINCT COUNT over partition" "SELECT DISTINCT COUNT(*) OVER (PARTITION BY GRP) FROM W;" "01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: COUNT alias: COUNT|: table: schema: owner: "

echo "--- 7. WINDOWS OVER A JOIN"
pin  "7 row_number over a self join" "SELECT W1.ID, ROW_NUMBER() OVER (ORDER BY W1.ID) FROM W W1 JOIN W W2 ON W1.ID = W2.ID ORDER BY 1;" "ID ROW_NUMBER|1 1|2 2|3 3|4 4|5 5"
pin  "7 ...partition by the other side" "SELECT A.ID, B.NAME, COUNT(*) OVER (PARTITION BY B.NAME) FROM T1 A LEFT JOIN TP B ON A.ID = B.ID ORDER BY A.ID;" "ID NAME COUNT|1 p 1|2 <null> 1"
pin  "7 ...a windowed expression over a join" "SELECT A.ID, A.N + SUM(A.N) OVER () FROM T1 A JOIN TP B ON A.ID = B.ID;" "ID ADD|1 10"
pin  "7 ...grouped join with a window" "SELECT W1.GRP, COUNT(*), RANK() OVER (ORDER BY COUNT(*) DESC) FROM W W1 JOIN W W2 ON W1.ID = W2.ID GROUP BY W1.GRP ORDER BY W1.GRP;" "GRP COUNT RANK|<null> 1 3|A 2 1|B 2 1"
pin  "7 ...comma join" "SELECT W1.ID, ROW_NUMBER() OVER (ORDER BY W1.ID DESC) FROM W W1, W W2 WHERE W1.ID = W2.ID;" "ID ROW_NUMBER|5 1|4 2|3 3|2 4|1 5"
pin  "7 ...join with no match rows" "SELECT A.ID, ROW_NUMBER() OVER (ORDER BY A.ID) FROM T1 A JOIN TP B ON A.ID = B.ID + 100;" ""
dpin "7 describe: the joined column keeps its table" "SELECT W1.ID, ROW_NUMBER() OVER (ORDER BY W1.ID) FROM W W1 JOIN W W2 ON W1.ID = W2.ID;" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: ID alias: ID|: table: W schema: PUBLIC owner: SYSDBA|02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: ROW_NUMBER alias: ROW_NUMBER|: table: schema: owner: "

echo "--- 8. SUM/AVG/MIN/MAX DISTINCT AND ALL; AGGREGATES OVER THE NULL LITERAL"
pin  "8 SUM(DISTINCT)" "SELECT SUM(DISTINCT I) FROM T;" "SUM|30"
pin  "8 AVG(DISTINCT)" "SELECT AVG(DISTINCT N) FROM T;" "AVG|1.87"
pin  "8 MIN/MAX(DISTINCT)" "SELECT MIN(DISTINCT I), MAX(DISTINCT I) FROM T;" "MIN MAX|10 20"
pin  "8 SUM(ALL)" "SELECT SUM(ALL I) FROM T;" "SUM|50"
pin  "8 AVG(DISTINCT I) truncates" "SELECT AVG(DISTINCT I) FROM T;" "AVG|15"
pin  "8 SUM(DISTINCT N) scaled" "SELECT SUM(DISTINCT N) FROM T;" "SUM|3.75"
pin  "8 SUM(DISTINCT) over no rows" "SELECT SUM(DISTINCT I) FROM T WHERE I > 100;" "SUM|<null>"
pin  "8 SUM(DISTINCT expr)" "SELECT SUM(DISTINCT I + 1) FROM T;" "SUM|32"
pin  "8 SUM(DISTINCT) grouped" "SELECT I, SUM(DISTINCT N) FROM T GROUP BY I ORDER BY I;" "I SUM|10 1.50|20 2.25"
pin  "8 SUM(DISTINCT) with NULLs" "SELECT SUM(DISTINCT VAL), COUNT(DISTINCT VAL), AVG(DISTINCT VAL) FROM W;" "SUM COUNT AVG|35 3 11"
pin  "8 SUM(DISTINCT NULL)" "SELECT SUM(DISTINCT NULL) FROM T;" "SUM|<null>"
pin  "8 the NULL literal folds" "SELECT SUM(NULL), COUNT(NULL), AVG(NULL), MIN(NULL), MAX(NULL) FROM T;" "SUM COUNT AVG MIN MAX|<null> 0 <null> <null> <null>"
pin  "8 ...over an empty table" "SELECT SUM(NULL), COUNT(NULL) FROM E;" "SUM COUNT|<null> 0"
pin  "8 ...grouped" "SELECT I, SUM(NULL) FROM T GROUP BY I ORDER BY I;" "I SUM|10 <null>|20 <null>"
pin  "8 ...beside COUNT(*)" "SELECT SUM(NULL), COUNT(*) FROM T;" "SUM COUNT|<null> 3"
pin  "8 COUNT(DISTINCT NULL)" "SELECT COUNT(DISTINCT NULL) FROM T;" "COUNT|0"
dpin "8 describe: SUM/AVG DISTINCT as the plain fold" "SELECT SUM(DISTINCT I), AVG(DISTINCT N), MIN(DISTINCT I) FROM T;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8|: name: SUM alias: SUM|: table: schema: owner: |02: sqltype: 580 INT64 Nullable scale: -2 subtype: 1 len: 8|: name: AVG alias: AVG|: table: schema: owner: |03: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: MIN alias: MIN|: table: schema: owner: "
dpin "8 describe: the NULL literal is CHAR(1)" "SELECT SUM(NULL), COUNT(NULL), AVG(NULL), MIN(NULL) FROM T;" "01: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|: name: SUM alias: SUM|: table: schema: owner: |02: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8|: name: COUNT alias: COUNT|: table: schema: owner: |03: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|: name: AVG alias: AVG|: table: schema: owner: |04: sqltype: 452 TEXT Nullable scale: 0 subtype: 0 len: 1 charset: 0 SYSTEM.NONE|: name: MIN alias: MIN|: table: schema: owner: "
pin  "8 SUM(DISTINCT) as an unordered window" "SELECT ID, SUM(DISTINCT VAL) OVER (PARTITION BY GRP) FROM W ORDER BY ID;" "ID SUM|1 30|2 30|3 20|4 20|5 5"
differs "8 RECORDED DISTINCT in an ordered window (engine raises its own)" "SELECT ID, SUM(DISTINCT VAL) OVER (ORDER BY ID) FROM W;"

echo "--- 9. FRAME BOUNDS: THE PARSER'S HOLES, THE BOUND RULE, THE NEGATIVE OFFSET"
pin  "9 UNBOUNDED FOLLOWING as bound 1: token unknown" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 62|-FOLLOWING"
pin  "9 UNBOUNDED PRECEDING as bound 2: token unknown" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND UNBOUNDED PRECEDING) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 78|-PRECEDING"
pin  "9 FOLLOWING then CURRENT ROW" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW) FROM W;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "9 CURRENT ROW then PRECEDING" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM W;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies CURRENT ROW, then <window frame bound 2> shall not specify PRECEDING"
pin  "9 FOLLOWING then PRECEDING" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND 1 PRECEDING) FROM W;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "9 ...RANGE the same" "SELECT ID, SUM(VAL) OVER (ORDER BY ID RANGE BETWEEN 1 FOLLOWING AND CURRENT ROW) FROM W;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "9 ...RANGE current row / unbounded preceding" "SELECT ID, SUM(VAL) OVER (ORDER BY ID RANGE BETWEEN CURRENT ROW AND UNBOUNDED PRECEDING) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 79|-PRECEDING"
pin  "9 shorthand n FOLLOWING: token unknown" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS 1 FOLLOWING) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 46|-FOLLOWING"
pin  "9 shorthand UNBOUNDED FOLLOWING: token unknown" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS UNBOUNDED FOLLOWING) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 54|-FOLLOWING"
pin  "9 the position counts lines" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN UNBOUNDED FOLLOWING AND CURRENT ROW) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 62|-FOLLOWING"
pin  "9 ...and inside a derived table" "SELECT * FROM (SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 2 FOLLOWING AND 1 PRECEDING) S FROM W) D;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "9 an empty frame answers NULLs" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING) FROM W;" "ID SUM|1 <null>|2 <null>|3 <null>|4 <null>|5 <null>"
pin  "9 ...preceding pair the wrong way round" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND 2 PRECEDING) FROM W;" "ID SUM|1 <null>|2 <null>|3 <null>|4 <null>|5 <null>"
pin  "9 ...and the right way round answers" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING) FROM W;" "ID SUM|1 <null>|2 10|3 30|4 40|5 20"
pin  "9 CURRENT ROW AND CURRENT ROW" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND CURRENT ROW) FROM W;" "ID SUM|1 10|2 20|3 20|4 <null>|5 5"
pin  "9 0 PRECEDING AND 0 FOLLOWING" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 0 PRECEDING AND 0 FOLLOWING) FROM W;" "ID SUM|1 10|2 20|3 20|4 <null>|5 5"
pin  "9 a negative offset raises at EXECUTE" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) FROM W;" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "9 ...parenthesised" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN (-1) PRECEDING AND CURRENT ROW) FROM W;" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "9 ...on bound 2" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND -1 FOLLOWING) FROM W;" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "9 ...RANGE" "SELECT ID, SUM(VAL) OVER (ORDER BY ID RANGE BETWEEN -1 PRECEDING AND CURRENT ROW) FROM W;" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "9 ...over an EMPTY table still raises" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) FROM E;" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "9 ...under WHERE 1=0 too" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) FROM W WHERE 1 = 0;" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "9 NULL PRECEDING: numerical type" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) FROM W;" "Statement failed, SQLSTATE = 42000|Window RANGE/ROWS/GROUPS PRECEDING/FOLLOWING value must be of a numerical type"
pin  "9 a string offset: numerical type" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 'a' PRECEDING AND CURRENT ROW) FROM W;" "Statement failed, SQLSTATE = 42000|Window RANGE/ROWS/GROUPS PRECEDING/FOLLOWING value must be of a numerical type"
pin  "9 the parse error outranks the bound rule" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW), SUM(VAL) OVER (ORDER BY ID ROWS UNBOUNDED FOLLOWING) FROM W;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 124|-FOLLOWING"
pin  "9 CONTROL the legal frames answer" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING), SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) FROM W;" "ID SUM SUM|1 30 55|2 50 45|3 40 25|4 25 5|5 5 5"
refused "9 RECORDED a fractional offset (engine rounds it)" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1.5 PRECEDING AND CURRENT ROW) FROM W;"
refused "9 RECORDED a column offset" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN ID PRECEDING AND CURRENT ROW) FROM W;"
refused "9 RECORDED a frame without ORDER BY" "SELECT ID, SUM(VAL) OVER (ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM W;"

echo "--- 10. DELIVERY ORDER: THE LAST SORTED WINDOW'S"
pin  "10 one sorted window: its order" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W;" "ID ROW_NUMBER|5 1|4 2|3 3|2 4|1 5"
pin  "10 two sorted windows: the LAST one's order, ties by the first's value" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC), ROW_NUMBER() OVER (ORDER BY VAL) FROM W;" "ID ROW_NUMBER ROW_NUMBER|4 2 1|5 1 2|1 5 3|3 3 4|2 4 5"
pin  "10 ...the other way round" "SELECT ID, ROW_NUMBER() OVER (ORDER BY VAL), ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W;" "ID ROW_NUMBER ROW_NUMBER|5 2 1|4 1 2|3 5 3|2 4 4|1 3 5"
pin  "10 partition only: partition order, NULL first" "SELECT ID, COUNT(*) OVER (PARTITION BY GRP) FROM W;" "ID COUNT|5 1|1 2|2 2|3 2|4 2"
pin  "10 OVER () alone: scan order" "SELECT ID, COUNT(*) OVER () FROM W;" "ID COUNT|1 5|2 5|3 5|4 5|5 5"
pin  "10 OVER () before a sorted one" "SELECT ID, COUNT(*) OVER (), ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W;" "ID COUNT ROW_NUMBER|5 5 1|4 5 2|3 5 3|2 5 4|1 5 5"
pin  "10 OVER () after a sorted one" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC), COUNT(*) OVER () FROM W;" "ID ROW_NUMBER COUNT|5 1 5|4 2 5|3 3 5|2 4 5|1 5 5"
pin  "10 a WHERE under it" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W WHERE VAL IS NOT NULL;" "ID ROW_NUMBER|5 1|3 2|2 3|1 4"
pin  "10 running sum by val, ties in scan order" "SELECT ID, SUM(VAL) OVER (ORDER BY VAL) FROM W;" "ID SUM|4 <null>|5 5|1 15|2 55|3 55"
pin  "10 partitioned then plain sorted" "SELECT ID, ROW_NUMBER() OVER (PARTITION BY GRP ORDER BY ID DESC), ROW_NUMBER() OVER (ORDER BY VAL DESC) FROM W;" "ID ROW_NUMBER ROW_NUMBER|2 1 1|3 2 2|1 2 3|5 1 4|4 1 5"
pin  "10 rank ties then row_number" "SELECT ID, RANK() OVER (ORDER BY VAL), ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W;" "ID RANK ROW_NUMBER|5 2 1|4 1 2|3 4 3|2 4 4|1 3 5"
pin  "10 two windows over one sort" "SELECT ID, ROW_NUMBER() OVER (ORDER BY VAL), SUM(VAL) OVER (ORDER BY VAL) FROM W;" "ID ROW_NUMBER SUM|4 1 <null>|5 2 5|1 3 15|2 4 55|3 5 55"
pin  "10 the statement ORDER BY still wins" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM W ORDER BY ID;" "ID ROW_NUMBER|1 5|2 4|3 3|4 2|5 1"

echo "--- 11. STATISTICAL FOLDS AS WINDOWS"
pin  "11 STDDEV_POP over a partition" "SELECT ID, STDDEV_POP(VAL) OVER (PARTITION BY GRP) FROM W ORDER BY ID;" "ID STDDEV_POP|1 5.000000000000000|2 5.000000000000000|3 0.000000000000000|4 0.000000000000000|5 0.000000000000000"
pin  "11 VAR_SAMP over ()" "SELECT ID, VAR_SAMP(VAL) OVER () FROM W ORDER BY ID;" "ID VAR_SAMP|1 56.25000000000000|2 56.25000000000000|3 56.25000000000000|4 56.25000000000000|5 56.25000000000000"
pin  "11 STDDEV_SAMP running" "SELECT ID, STDDEV_SAMP(VAL) OVER (ORDER BY ID) FROM W ORDER BY ID;" "ID STDDEV_SAMP|1 0.000000000000000|2 7.071067811865476|3 5.773502691896256|4 5.773502691896256|5 7.500000000000000"
pin  "11 VAR_POP framed" "SELECT ID, VAR_POP(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM W ORDER BY ID;" "ID VAR_POP|1 0.000000000000000|2 25.00000000000000|3 0.000000000000000|4 0.000000000000000|5 0.000000000000000"
pin  "11 ...over an empty table" "SELECT ID, STDDEV_POP(VAL) OVER (PARTITION BY GRP) FROM E;" ""
dpin "11 describe: STDDEV_POP window is DOUBLE" "SELECT ID, STDDEV_POP(VAL) OVER (PARTITION BY GRP) FROM W;" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: ID alias: ID|: table: W schema: PUBLIC owner: SYSDBA|02: sqltype: 480 DOUBLE scale: 0 subtype: 0 len: 8|: name: STDDEV_POP alias: STDDEV_POP|: table: schema: owner: "
refused "11 RECORDED LIST as a window" "SELECT ID, LIST(VAL) OVER (PARTITION BY GRP) FROM W ORDER BY ID;"
refused "11 RECORDED PERCENTILE_CONT as a window" "SELECT ID, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VAL) OVER (PARTITION BY GRP) FROM W ORDER BY ID;"

echo "--- 12. RECORDED: THE CLUSTER'S REMAINING BOUNDARIES"
refused "12 RECORDED CREATE VIEW over a GROUP BY" "CREATE VIEW AGV AS SELECT GRP, COUNT(*) C FROM W GROUP BY GRP;"
refused "12 RECORDED CREATE VIEW over an aggregate" "CREATE VIEW AGV4 AS SELECT COUNT(*) C FROM W;"
refused "12 RECORDED CREATE VIEW over a window" "CREATE VIEW VWIN AS SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM W;"
refused "12 RECORDED LAG with a NULL offset" "SELECT ID, LEAD(VAL, NULL) OVER (ORDER BY ID) FROM W ORDER BY ID;"
refused "12 RECORDED LAG with a column offset" "SELECT ID, LAG(VAL, ID - 1) OVER (ORDER BY ID) FROM W ORDER BY ID;"
refused "12 RECORDED RANGE offset over a NUMERIC key" "SELECT ID, SUM(AMT) OVER (ORDER BY AMT RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM W ORDER BY ID;"
refused "12 RECORDED RANGE offset over a DATE key" "SELECT ID, COUNT(*) OVER (ORDER BY D RANGE BETWEEN 31 PRECEDING AND CURRENT ROW) FROM W ORDER BY ID;"
refused "12 RECORDED MIN over a BLOB" "SELECT MIN(BL) FROM CS;"
refused "12 RECORDED COUNT(DISTINCT blob)" "SELECT COUNT(DISTINCT BL) FROM CS;"

echo "--- 13. CREATE OR ALTER VIEW: by existence"
pin  "13 CREATE OR ALTER VIEW creates when absent" "CREATE OR ALTER VIEW V2 AS SELECT ID, S FROM T1; COMMIT; SELECT * FROM V2 ORDER BY ID;" "ID S|1 a|2 b"
pin  "13 ...and redefines when present" "CREATE OR ALTER VIEW V2 AS SELECT ID, N FROM T1; COMMIT; SELECT * FROM V2 ORDER BY ID; CREATE OR ALTER VIEW V2 (A, B, C) AS SELECT ID, N, S FROM T1; COMMIT; SELECT * FROM V2 ORDER BY A;" "ID N|1 5|2 7|A B C|1 5 a|2 7 b"
dpin "13 describe: the redefined view" "SELECT * FROM V2;" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: A alias: A|: table: V2 schema: PUBLIC owner: SYSDBA|02: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4|: name: B alias: B|: table: V2 schema: PUBLIC owner: SYSDBA|03: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 10 charset: 0 SYSTEM.NONE|: name: C alias: C|: table: V2 schema: PUBLIC owner: SYSDBA"

echo "--- 14. GROUP BY A SELECT-LIST ALIAS THAT SHADOWS A COLUMN"
pin  "14 GROUP BY VAL, ID under VAL ID groups by VAL twice over" "SELECT VAL ID, COUNT(*) FROM W GROUP BY VAL, ID;" "ID COUNT|<null> 1|5 1|10 1|20 2"
pin  "14 ...GROUP BY the alias alone" "SELECT VAL ID, COUNT(*) FROM W GROUP BY ID;" "ID COUNT|<null> 1|5 1|10 1|20 2"
pin  "14 ...ORDER BY the alias" "SELECT VAL ID, COUNT(*) FROM W GROUP BY ID ORDER BY ID DESC;" "ID COUNT|20 2|10 1|5 1|<null> 1"
pin  "14 ...GROUP BY the column, ORDER BY the alias" "SELECT VAL ID, COUNT(*) FROM W GROUP BY VAL ORDER BY ID;" "ID COUNT|<null> 1|5 1|10 1|20 2"
pin  "14 an aliased EXPRESSION shadows the column" "SELECT VAL + 1 ID, COUNT(*) FROM W GROUP BY ID;" "ID COUNT|<null> 1|6 1|11 1|21 2"
pin  "14 ...and beside its own column" "SELECT VAL + 1 ID, COUNT(*) FROM W GROUP BY ID, VAL;" "ID COUNT|<null> 1|6 1|11 1|21 2"
pin  "14 a text column's name as the alias" "SELECT GRP VAL, COUNT(*) FROM W GROUP BY GRP, VAL;" "VAL COUNT|<null> 1|A 2|B 2"
pin  "14 the aggregate's argument is the COLUMN" "SELECT VAL ID, MAX(ID) FROM W GROUP BY ID;" "ID MAX|<null> 4|5 5|10 1|20 3"
pin  "14 ...SUM of the shadowed column" "SELECT GRP VAL, SUM(VAL) FROM W GROUP BY VAL;" "VAL SUM|<null> 5|A 30|B 20"
pin  "14 HAVING names the column" "SELECT VAL ID, COUNT(*) FROM W GROUP BY ID HAVING VAL > 5;" "ID COUNT|10 1|20 2"
pin  "14 WHERE names the column" "SELECT VAL ID, COUNT(*) FROM W WHERE ID > 1 GROUP BY ID;" "ID COUNT|<null> 1|5 1|20 2"
pin  "14 swapped aliases" "SELECT ID VAL, VAL ID, COUNT(*) FROM W GROUP BY ID, VAL;" "VAL ID COUNT|4 <null> 1|5 5 1|1 10 1|2 20 1|3 20 1"
pin  "14 a second key beside the alias" "SELECT VAL ID, GRP, COUNT(*) FROM W GROUP BY GRP, ID;" "ID GRP COUNT|5 <null> 1|10 A 1|20 A 1|<null> B 1|20 B 1"
pin  "14 the same key thrice" "SELECT VAL ID, COUNT(*) FROM W GROUP BY ID, VAL, ID;" "ID COUNT|<null> 1|5 1|10 1|20 2"
pin  "14 a quoted alias" "SELECT VAL \"id\", COUNT(*) FROM W GROUP BY \"id\";" "id COUNT|<null> 1|5 1|10 1|20 2"
pin  "14 FIRST over it" "SELECT FIRST 2 VAL ID, COUNT(*) FROM W GROUP BY ID ORDER BY ID;" "ID COUNT|<null> 1|5 1"
pin  "14 in a derived table" "SELECT * FROM (SELECT VAL ID, COUNT(*) C FROM W GROUP BY ID) D ORDER BY 1;" "ID C|<null> 1|5 1|10 1|20 2"
pin  "14 a FIELD item beside the alias: 42702" "SELECT ID, VAL ID, COUNT(*) FROM W GROUP BY ID;" "Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and an alias in the select list with name|-ID"
pin  "14 ...a qualified field item too" "SELECT W.ID, VAL ID, COUNT(*) FROM W GROUP BY ID;" "Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and an alias in the select list with name|-ID"
pin  "14 ...without an aggregate" "SELECT ID, VAL ID FROM W GROUP BY ID;" "Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and an alias in the select list with name|-ID"
pin  "14 ...ordinals resolve without ambiguity" "SELECT ID, VAL ID, COUNT(*) FROM W GROUP BY 1, 2;" "ID ID COUNT|1 10 1|2 20 1|3 20 1|4 <null> 1|5 5 1"
pin  "14 windowed: RANK over the alias grouping" "SELECT VAL ID, COUNT(*), RANK() OVER (ORDER BY COUNT(*)) FROM W GROUP BY VAL, ID;" "ID COUNT RANK|5 1 1|10 1 1|<null> 1 1|20 2 4"
pin  "14 windowed: ROW_NUMBER over GRP VAL" "SELECT GRP VAL, COUNT(*), ROW_NUMBER() OVER (ORDER BY GRP) FROM W GROUP BY GRP, VAL;" "VAL COUNT ROW_NUMBER|<null> 1 1|A 2 2|B 2 3"
pin  "14 windowed: ORDER BY the alias" "SELECT VAL ID, COUNT(*), RANK() OVER (ORDER BY COUNT(*)) FROM W GROUP BY ID ORDER BY ID;" "ID COUNT RANK|<null> 1 1|5 1 1|10 1 1|20 2 4"
pin  "14 windowed: the window sorts by the column" "SELECT VAL ID, ROW_NUMBER() OVER (ORDER BY VAL) FROM W GROUP BY VAL, ID ORDER BY ID;" "ID ROW_NUMBER|<null> 1|5 2|10 3|20 4"
pin  "14 windowed: PARTITION BY the column" "SELECT VAL ID, RANK() OVER (PARTITION BY VAL ORDER BY COUNT(*)) FROM W GROUP BY VAL, ID ORDER BY ID;" "ID RANK|<null> 1|5 1|10 1|20 1"
pin  "14 windowed: HAVING the column" "SELECT VAL ID, COUNT(*), RANK() OVER (ORDER BY COUNT(*)) FROM W GROUP BY ID HAVING VAL > 5;" "ID COUNT RANK|10 1 1|20 2 2"
pin  "14 windowed, in a derived table" "SELECT * FROM (SELECT VAL ID, COUNT(*) C, RANK() OVER (ORDER BY COUNT(*)) R FROM W GROUP BY VAL, ID) D ORDER BY R, 1;" "ID C R|<null> 1 1|5 1 1|10 1 1|20 2 4"
pin  "14 windowed: a field item beside the alias: 42702" "SELECT ID, VAL ID, COUNT(*), RANK() OVER (ORDER BY COUNT(*)) FROM W GROUP BY ID;" "Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and an alias in the select list with name|-ID"
pin  "14 windowed: an alias that shadows nothing" "SELECT GRP G, COUNT(*) C, RANK() OVER (ORDER BY COUNT(*) DESC) FROM W GROUP BY G ORDER BY G;" "G C RANK|<null> 1 3|A 2 1|B 2 1"
pin  "14 CONTROL: the windowless alias" "SELECT GRP G, COUNT(*) C FROM W GROUP BY G ORDER BY G;" "G C|<null> 1|A 2|B 2"
differs "14 RECORDED the window's ORDER BY names the column (engine -104)" "SELECT VAL ID, ROW_NUMBER() OVER (ORDER BY ID) FROM W GROUP BY VAL, ID ORDER BY ID;"
differs "14 RECORDED PARTITION BY the shadowed name (engine -104)" "SELECT VAL ID, RANK() OVER (PARTITION BY ID ORDER BY COUNT(*)) FROM W GROUP BY VAL, ID;"
differs "14 RECORDED a qualified key is the column (engine -104)" "SELECT VAL ID, COUNT(*) FROM W GROUP BY W.ID;"
refused "14 RECORDED ...beside the alias (engine groups five ways)" "SELECT VAL ID, COUNT(*) FROM W GROUP BY ID, W.ID;"
differs "14 RECORDED ORDER BY the qualified column (engine -104)" "SELECT VAL ID, COUNT(*) FROM W GROUP BY VAL, ID ORDER BY W.ID;"
differs "14 RECORDED HAVING the alias is the column (engine -104)" "SELECT VAL ID, COUNT(*) FROM W GROUP BY ID HAVING ID > 5;"
differs "14 RECORDED HAVING an alias that shadows nothing (engine -206)" "SELECT VAL X, COUNT(*) FROM W GROUP BY X HAVING X > 5;"

echo "--- 15. FRAME BOUNDS IN A NAMED WINDOW AND INSIDE DML"
pin  "15 named window: FOLLOWING then CURRENT ROW" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW);" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "15 named window: UNBOUNDED FOLLOWING as bound 1" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 87|-FOLLOWING"
pin  "15 named window: CURRENT ROW then PRECEDING" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN CURRENT ROW AND 1 PRECEDING);" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies CURRENT ROW, then <window frame bound 2> shall not specify PRECEDING"
pin  "15 named window: the shorthand FOLLOWING" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS 1 FOLLOWING);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 71|-FOLLOWING"
pin  "15 named window: a NULL offset" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN NULL PRECEDING AND CURRENT ROW);" "Statement failed, SQLSTATE = 42000|Window RANGE/ROWS/GROUPS PRECEDING/FOLLOWING value must be of a numerical type"
pin  "15 the SECOND named window" "SELECT ID, SUM(VAL) OVER W2 FROM W WINDOW W1 AS (ORDER BY ID), W2 AS (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW);" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "15 ...the parse error outranks the bound rule" "SELECT ID, SUM(VAL) OVER W1, SUM(VAL) OVER W2 FROM W WINDOW W1 AS (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW), W2 AS (ORDER BY ID ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 165|-FOLLOWING"
pin  "15 named window: a negative offset raises at EXECUTE" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN -1 PRECEDING AND CURRENT ROW);" "ID SUM|Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative"
pin  "15 CONTROL: a legal named frame" "SELECT ID, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING);" "ID SUM|1 30|2 50|3 40|4 25|5 5"
pin  "15 UPDATE over an illegal frame changes nothing" "UPDATE W SET VAL = 0 WHERE ID IN (SELECT ID FROM (SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW) S FROM W) WHERE S IS NULL); SELECT ID, VAL FROM W ORDER BY ID; ROLLBACK;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW|ID VAL|1 10|2 20|3 20|4 <null>|5 5"
pin  "15 DELETE over an illegal frame deletes nothing" "DELETE FROM W WHERE ID IN (SELECT ID FROM (SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN UNBOUNDED FOLLOWING AND UNBOUNDED FOLLOWING) S FROM W)); SELECT COUNT(*) FROM W; ROLLBACK;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 105|-FOLLOWING|COUNT|5"
pin  "15 INSERT .. SELECT over an illegal frame inserts nothing" "INSERT INTO E SELECT ID, GRP, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM W; SELECT COUNT(*) FROM E; ROLLBACK;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies CURRENT ROW, then <window frame bound 2> shall not specify PRECEDING|COUNT|0"
pin  "15 ...through a named window" "INSERT INTO E SELECT ID, GRP, SUM(VAL) OVER WIN FROM W WINDOW WIN AS (ORDER BY ID ROWS BETWEEN CURRENT ROW AND 1 PRECEDING); SELECT COUNT(*) FROM E; ROLLBACK;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies CURRENT ROW, then <window frame bound 2> shall not specify PRECEDING|COUNT|0"
pin  "15 DELETE over a NULL offset" "DELETE FROM W WHERE ID IN (SELECT ID FROM (SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN NULL PRECEDING AND CURRENT ROW) S FROM W)); SELECT COUNT(*) FROM W; ROLLBACK;" "Statement failed, SQLSTATE = 42000|Window RANGE/ROWS/GROUPS PRECEDING/FOLLOWING value must be of a numerical type|COUNT|5"
pin  "15 UPDATE over a negative offset raises at EXECUTE" "UPDATE W SET VAL = 0 WHERE ID IN (SELECT ID FROM (SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN -1 PRECEDING AND CURRENT ROW) S FROM W) WHERE S IS NULL); SELECT ID, VAL FROM W ORDER BY ID; ROLLBACK;" "Statement failed, SQLSTATE = 42000|Invalid PRECEDING or FOLLOWING offset in window function: cannot be negative|ID VAL|1 10|2 20|3 20|4 <null>|5 5"
pin  "15 a select-list subquery's frame" "SELECT ID, (SELECT SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW) FROM W X WHERE X.ID = W.ID) FROM W;" "Statement failed, SQLSTATE = 42000|If <window frame bound 1> specifies FOLLOWING, then <window frame bound 2> shall not specify PRECEDING or CURRENT ROW"
pin  "15 CONTROL: a legal frame in an UPDATE" "UPDATE W SET VAL = 0 WHERE ID IN (SELECT ID FROM (SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) S FROM W) WHERE S IS NULL); SELECT ID, VAL FROM W ORDER BY ID; ROLLBACK;" "ID VAL|1 10|2 20|3 20|4 <null>|5 5"
differs "15 RECORDED an illegal frame inside EXECUTE BLOCK (engine's bound rule)" "EXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN FOR SELECT SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 1 FOLLOWING AND CURRENT ROW) FROM W INTO :N DO SUSPEND; END"

echo "--- 16. THE SORT RECORD'S TIES ABOVE AND INSIDE A WINDOW; VAR/STDDEV OVER A COMPUTED INT128; LITERALS, DUPLICATE WINDOWS, OFFSETS PAST INTEGER"
pin  "16 ORDER BY above a window ties by the select list's field" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM RT ORDER BY K;" "ID ROW_NUMBER|6 5|9 2|1 10|3 8|5 6|8 3|2 9|4 7|7 4|10 1"
pin  "16 ...an expression's field breaks the tie, not its value" "SELECT 11 - ID R, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM RT ORDER BY K;" "R ROW_NUMBER|5 5|2 2|10 10|8 8|6 6|3 3|9 9|7 7|4 4|1 1"
pin  "16 ...the fields in written order, S before ID" "SELECT S, ID, ROW_NUMBER() OVER (ORDER BY ID DESC) FROM RT ORDER BY K;" "S ID ROW_NUMBER|a 9 2|b 6 5|a 3 8|b 1 10|c 8 3|<null> 5 6|a 2 9|a 10 1|b 7 4|c 4 7"
pin  "16 CONTROL: the window's stream written first leads the record" "SELECT ROW_NUMBER() OVER (ORDER BY ID DESC) RN, ID FROM RT ORDER BY K;" "RN ID|2 9|5 6|3 8|6 5|8 3|10 1|1 10|4 7|7 4|9 2"
pin  "16 ...a NULL VARCHAR shares word 0 with its length: it leads" "SELECT S, ROW_NUMBER() OVER (ORDER BY ID) FROM RT ORDER BY K;" "S ROW_NUMBER|a 9|b 6|<null> 5|a 3|b 1|c 8|a 2|a 10|b 7|c 4"
pin  "16 ...a PARTITION BY stream's extra slot moves the length out: it trails" "SELECT S, COUNT(*) OVER (PARTITION BY V) FROM RT ORDER BY K;" "S COUNT|a 3|b 3|a 3|b 3|c 3|<null> 3|a 3|a 3|b 1|c 3"
pin  "16 OFFSET/FETCH over the tie order: a different row set" "SELECT ID, S, ROW_NUMBER() OVER (ORDER BY V DESC) FROM RT ORDER BY S DESC NULLS LAST OFFSET 2 ROWS FETCH FIRST 4 ROWS ONLY;" "ID S ROW_NUMBER|1 b 1|6 b 5|7 b 10|2 a 7"
pin  "16 FIRST over a grouped ORDER BY window" "SELECT FIRST 4 S, K FROM RT GROUP BY S, K ORDER BY COUNT(*) OVER (PARTITION BY S) DESC;" "S K|a 1|a 2|b 1|b 2"
pin  "16 grouped, ORDER BY a window over an aggregate" "SELECT K, S, MAX(V) FROM RT GROUP BY K, S ORDER BY RANK() OVER (ORDER BY MAX(V) DESC);" "K S MAX|1 b 3|1 c 3|2 c 3|1 a 2|2 a 2|<null> b 2|<null> a 1|1 <null> 1|2 b <null>"
pin  "16 a join's ORDER BY above a window" "SELECT RW.ID, RG.NAME, ROW_NUMBER() OVER (ORDER BY RW.VAL) FROM RW LEFT JOIN RG ON RG.GRP = RW.GRP ORDER BY RW.GRP;" "ID NAME ROW_NUMBER|5 <null> 2|1 alpha 3|2 alpha 6|7 alpha 4|3 beta 7|4 beta 1|6 <null> 5"
pin  "16 a NULL group key ties by its flag and length: ROW_NUMBER over COUNT" "SELECT GRP, ROW_NUMBER() OVER (ORDER BY COUNT(*)) FROM RW GROUP BY GRP;" "GRP ROW_NUMBER|<null> 1|C 2|B 3|A 4"
pin  "16 ...descending" "SELECT GRP, ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) FROM RW GROUP BY GRP;" "GRP ROW_NUMBER|A 1|B 2|<null> 3|C 4"
pin  "16 ...FIRST 1 takes the NULL group" "SELECT FIRST 1 GRP, RANK() OVER (ORDER BY COUNT(*)) FROM RW GROUP BY GRP;" "GRP RANK|<null> 1"
pin  "16 a LEFT JOIN's NULL keys tie by the ON-only fields" "SELECT RW.ID, ROW_NUMBER() OVER (ORDER BY RG.NAME) FROM RW LEFT JOIN RG ON RG.GRP = RW.GRP;" "ID ROW_NUMBER|6 1|5 2|1 3|2 4|7 5|3 6|4 7"
pin  "16 VAR_POP over a derived SUM of NUMERIC(18,2)" "SELECT VAR_POP(S) FROM (SELECT SUM(Z) S FROM RH GROUP BY ID);" "VAR_POP|0.8750"
pin  "16 VAR_POP over a derived X + 0 of NUMERIC(38,4)" "SELECT VAR_POP(X2) FROM (SELECT X + 0 X2 FROM RH);" "VAR_POP|0.87500000"
pin  "16 STDDEV_SAMP / STDDEV_POP / VAR_SAMP over the same" "SELECT STDDEV_SAMP(S), STDDEV_POP(S), VAR_SAMP(S) FROM (SELECT SUM(Z) S FROM RH GROUP BY ID);" "STDDEV_SAMP STDDEV_POP VAR_SAMP|1.145643923738960001647011798432002 0.8750 1.3125"
pin  "16 ...in a HAVING" "SELECT VAR_POP(S) FROM (SELECT SUM(Z) S FROM RH GROUP BY ID) HAVING VAR_POP(S) > 0;" "VAR_POP|0.8750"
pin  "16 VAR_POP(SUM(N)) OVER () over a GROUP BY" "SELECT T, VAR_POP(SUM(N)) OVER () FROM RC GROUP BY T;" "T VAR_POP|<null> 0.40625000|x 0.40625000|y 0.40625000"
pin  "16 VAR_POP(SUM(B)) OVER () over BIGINT sums" "SELECT T, VAR_POP(SUM(B)) OVER () FROM RC GROUP BY T;" "T VAR_POP|<null> 1.79999999999999999920000000000000E+37|x 1.79999999999999999920000000000000E+37|y 1.79999999999999999920000000000000E+37"
pin  "16 STDDEV_POP / VAR_SAMP / COVAR_POP windows over a derived SUM" "SELECT STDDEV_POP(X) OVER (), VAR_SAMP(X) OVER (), COVAR_POP(X, X) OVER () FROM (SELECT T, SUM(N) X FROM RC GROUP BY T);" "STDDEV_POP VAR_SAMP COVAR_POP|0.40625000 0.60937500 0.40625000|0.40625000 0.60937500 0.40625000|0.40625000 0.60937500 0.40625000"
pin  "16 a running VAR_POP over a derived computed INT128" "SELECT ID, VAR_POP(X2) OVER (ORDER BY ID) FROM (SELECT ID, X + 0 X2 FROM RH);" "ID VAR_POP|1 0E-8|2 0.14062500|3 0.87500000"
pin  "16 a string literal's ')' in a grouped windowed select" "SELECT GRP, ')' X, COUNT(*), ROW_NUMBER() OVER (ORDER BY GRP DESC) FROM RW GROUP BY GRP;" "GRP X COUNT ROW_NUMBER|C ) 1 1|B ) 2 2|A ) 3 3|<null> ) 1 4"
pin  "16 ...'a,b'" "SELECT GRP, 'a,b' X, ROW_NUMBER() OVER (ORDER BY GRP DESC) FROM RW GROUP BY GRP;" "GRP X ROW_NUMBER|C a,b 1|B a,b 2|A a,b 3|<null> a,b 4"
pin  "16 ...'OVER (' on the plain path" "SELECT ID, 'OVER (', ROW_NUMBER() OVER (ORDER BY ID DESC) FROM RW;" "ID CONSTANT ROW_NUMBER|7 OVER ( 1|6 OVER ( 2|5 OVER ( 3|4 OVER ( 4|3 OVER ( 5|2 OVER ( 6|1 OVER ( 7"
pin  "16 ...'(' over a join" "SELECT RW.ID, '(' X, ROW_NUMBER() OVER (ORDER BY RW.ID DESC) FROM RW JOIN RW W2 ON W2.ID = RW.ID;" "ID X ROW_NUMBER|7 ( 1|6 ( 2|5 ( 3|4 ( 4|3 ( 5|2 ( 6|1 ( 7"
pin  "16 a duplicate named window is -204" "SELECT ID, SUM(VAL) OVER WIN FROM RW WINDOW WIN AS (ORDER BY ID), WIN AS (ORDER BY VAL);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Duplicate window definition for WIN"
pin  "16 a frame offset past INTEGER raises 22003 at execute" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 3000000000 PRECEDING AND CURRENT ROW) FROM RW;" "ID SUM|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin  "16 ...2147483648, over no rows too" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN CURRENT ROW AND 2147483648 FOLLOWING) FROM RW WHERE 1 = 0;" "ID SUM|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin  "16 ...the shorthand" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS 3000000000 PRECEDING) FROM RW;" "ID SUM|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin  "16 CONTROL: 2147483647 answers" "SELECT ID, SUM(VAL) OVER (ORDER BY ID ROWS BETWEEN 2147483647 PRECEDING AND CURRENT ROW) FROM RW;" "ID SUM|1 10|2 30|3 50|4 50|5 55|6 65|7 75"

echo "--- 17. A WINDOW OVER A DERIVED TABLE SORTS THE RELATION'S RECORD; RANGE OFFSETS PAST INTEGER; GROUPED EXPRESSION ITEMS; ORDER BY OVER A WINDOWED DERIVED TABLE"
pin  "17 a window over a derived table with a WHERE ties by the relation's record" "SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT S, K FROM RU WHERE ID > 2);" "S ROW_NUMBER|a 1|b 2|3|a 4|c 5|<null> 6|b 7|b 8|c 9|ab 10"
pin  "17 ...a WHERE on a field the derived table does not expose" "SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT S, K FROM RU WHERE K2 > 0);" "S ROW_NUMBER|b 1|2|b 3|c 4|<null> 5|a 6|c 7|ab 8"
pin  "17 ...a CTE" "WITH C AS (SELECT S, K FROM RU WHERE ID > 2) SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM C;" "S ROW_NUMBER|a 1|b 2|3|a 4|c 5|<null> 6|b 7|b 8|c 9|ab 10"
pin  "17 ...qualified, an inner ORDER BY, an outer WHERE" "SELECT X.S, ROW_NUMBER() OVER (ORDER BY X.K) FROM (SELECT S, K FROM RU WHERE ID > 2 ORDER BY ID) X WHERE X.K IS NOT NULL;" "S ROW_NUMBER|1|a 2|c 3|<null> 4|b 5|b 6|c 7|ab 8"
pin  "17 ...FIRST inside the derived table" "SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT FIRST 20 S, K FROM RU WHERE ID > 2);" "S ROW_NUMBER|a 1|b 2|3|a 4|c 5|<null> 6|b 7|b 8|c 9|ab 10"
pin  "17 ...a view" "SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT S, K FROM RUV WHERE ID > 2);" "S ROW_NUMBER|a 1|b 2|3|a 4|c 5|<null> 6|b 7|b 8|c 9|ab 10"
pin  "17 ...the relation's field order, not the derived table's" "SELECT S, K2, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT S, K, K2 FROM RU);" "S K2 ROW_NUMBER|b 2 1|a <null> 2|1 3|b 1 4|c 1 5|a <null> 6|<null> 2 7|a 2 8|c 1 9|ab 2 10|b <null> 11|b <null> 12"
pin  "17 ...DISTINCT inside the derived table" "SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT DISTINCT S, K FROM RU WHERE ID > 2);" "S ROW_NUMBER|a 1|b 2|3|a 4|c 5|<null> 6|b 7|c 8|ab 9"
pin  "17 CONTROL: a WHERE on the key keeps the NULL second" "SELECT S, ROW_NUMBER() OVER (ORDER BY K) FROM (SELECT S, K FROM RU WHERE K > -5);" "S ROW_NUMBER|1|<null> 2|a 3|b 4|c 5|a 6|b 7|b 8|c 9|ab 10"
pin  "17 a RANGE offset past INTEGER answers" "SELECT ID, SUM(V) OVER (ORDER BY ID RANGE BETWEEN 3000000000 PRECEDING AND CURRENT ROW) FROM RU;" "ID SUM|1 3|2 4|3 6|4 9|5 10|6 12|7 12|8 15|9 16|10 18|11 19|12 22"
pin  "17 ...the shorthand" "SELECT ID, SUM(V) OVER (ORDER BY ID RANGE 3000000000 PRECEDING) FROM RU;" "ID SUM|1 3|2 4|3 6|4 9|5 10|6 12|7 12|8 15|9 16|10 18|11 19|12 22"
pin  "17 ...over a BIGINT key, both bounds" "SELECT ID, SUM(V) OVER (ORDER BY B RANGE BETWEEN 3000000000 PRECEDING AND 3000000000 FOLLOWING) FROM RU;" "ID SUM|5 4|12 4|3 18|7 18|4 18|10 18|8 18|1 18|6 18|11 18|2 18|9 18"
pin  "17 ...over no rows: no rows" "SELECT ID, SUM(V) OVER (ORDER BY ID RANGE BETWEEN CURRENT ROW AND 2147483648 FOLLOWING) FROM RU WHERE 1 = 0;" ""
pin  "17 ...in INSERT .. SELECT" "INSERT INTO E (ID, VAL) SELECT ID, SUM(V) OVER (ORDER BY ID RANGE BETWEEN 3000000000 PRECEDING AND CURRENT ROW) FROM RU; SELECT COUNT(*), SUM(VAL) FROM E; ROLLBACK;" "COUNT SUM|12 146"
pin  "17 grouped, ORDER BY an aggregate item: FIRST takes the engine's rows" "SELECT FIRST 2 S, COUNT(*), ROW_NUMBER() OVER (ORDER BY S) FROM RU GROUP BY S ORDER BY COUNT(*);" "S COUNT ROW_NUMBER|1 2|<null> 1 1"
pin  "17 ...DESC" "SELECT S, COUNT(*), ROW_NUMBER() OVER (ORDER BY S) FROM RU GROUP BY S ORDER BY COUNT(*) DESC;" "S COUNT ROW_NUMBER|b 4 5|a 3 3|c 2 6|1 2|<null> 1 1|ab 1 4"
pin  "17 ...then a group key" "SELECT K, S, COUNT(*), ROW_NUMBER() OVER (ORDER BY K) FROM RU GROUP BY K, S ORDER BY COUNT(*), K;" "K S COUNT ROW_NUMBER|<null> a 1 1|<null> b 1 2|1 1 3|1 <null> 1 7|1 a 1 4|1 b 1 5|1 c 1 6|2 a 1 8|2 c 1 10|2 ab 1 11|2 b 2 9"
pin  "17 grouped by an expression's alias" "SELECT K + 1 KK, COUNT(*), ROW_NUMBER() OVER (ORDER BY COUNT(*)) FROM RU GROUP BY KK;" "KK COUNT ROW_NUMBER|<null> 2 1|2 5 2|3 5 3"
pin  "17 ...by the expression" "SELECT K + 1, COUNT(*), ROW_NUMBER() OVER (ORDER BY COUNT(*)) FROM RU GROUP BY K + 1;" "ADD COUNT ROW_NUMBER|<null> 2 1|2 5 2|3 5 3"
pin  "17 ...by a function" "SELECT UPPER(S) US, COUNT(*), ROW_NUMBER() OVER (ORDER BY COUNT(*)) FROM RU GROUP BY UPPER(S);" "US COUNT ROW_NUMBER|1 1|AB 1 2|<null> 1 3|C 2 4|A 3 5|B 4 6"
pin  "17 ...DENSE_RANK over MAX" "SELECT K * 10 + 1, MAX(V), DENSE_RANK() OVER (ORDER BY MAX(V)) FROM RU GROUP BY K * 10 + 1;" "ADD MAX DENSE_RANK|<null> 2 1|11 3 2|21 3 2"
pin  "17 ...by ordinal" "SELECT S || 'x' SX, COUNT(*), RANK() OVER (ORDER BY COUNT(*)) FROM RU GROUP BY 1;" "SX COUNT RANK|x 1 1|abx 1 1|<null> 1 1|cx 2 4|ax 3 5|bx 4 6"
pin  "17 CONTROL: an expression over a bare group key" "SELECT K + 1, K, COUNT(*), ROW_NUMBER() OVER (ORDER BY COUNT(*)) FROM RU GROUP BY K;" "ADD K COUNT ROW_NUMBER|<null> <null> 2 1|2 1 5 2|3 2 5 3"
pin  "17 ORDER BY over a windowed derived table ties by its window streams" "SELECT X.S, RN FROM (SELECT S, K, ROW_NUMBER() OVER (ORDER BY K) RN FROM RU) X ORDER BY X.K;" "S RN|a 1|b 2|3|<null> 7|a 4|b 5|c 6|a 8|b 9|b 10|c 11|ab 12"
pin  "17 ...a CTE" "WITH C AS (SELECT S, K, ROW_NUMBER() OVER (ORDER BY V) RN FROM RU) SELECT * FROM C ORDER BY K;" "S K RN|a <null> 4|b <null> 8|1 2|<null> 1 5|a 1 6|b 1 9|c 1 11|a 2 3|b 2 1|b 2 10|c 2 12|ab 2 7"
pin  "17 ...FIRST takes the engine's rows" "SELECT FIRST 5 X.S, RN FROM (SELECT S, K, ROW_NUMBER() OVER (ORDER BY K) RN FROM RU) X ORDER BY X.K;" "S RN|a 1|b 2|3|<null> 7|a 4"
pin  "17 ...a PARTITION BY stream's slot" "SELECT X.S, RN FROM (SELECT K, S, SUM(V) OVER (PARTITION BY K2) RN FROM RU) X ORDER BY X.K;" "S RN|a 6|b 6|10|a 6|b 10|c 10|<null> 6|a 6|b 6|b 6|c 10|ab 6"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-aggplan-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 287 ]; then echo "FAIL only $ran checks ran (floor 287)"; fail=1; fi
exit $fail
