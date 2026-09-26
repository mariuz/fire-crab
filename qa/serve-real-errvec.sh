#!/bin/bash
# THE ENGINE'S OWN VECTOR, NOT A BARE `42000 Dynamic SQL Error` - measured
# on engine 2182 and matched, cell by cell, SQLSTATE, message lines,
# line/column and PHASE (the two-phase rig, qa/ddlphase.c, where isql
# cannot tell prepare from execute).
#
# A statement the planners refused without posting a vector reached the
# client as a bare `42000 / Dynamic SQL Error`, and most of them are
# statements the engine refuses too, with a vector of its own. The root:
# the refusal arm had nothing to say. [diagnose_refusal] now reads such a
# statement - AFTER the refusal, over the text as sent, in the engine's
# pass order (the -206 qualifier scan's reader, in its BARE mode) - and
# names the engine's vector where it can place it exactly, leaving the
# refusal as it was otherwise; only a refused statement reaches it.
#
#   1. a bare name no context holds: 42S22 -206 "Column unknown" at its
#      line and column (was 42000) - every clause, the pass order, a
#      quoted name's case, a non-reserved word, an alias only where the
#      ORDER BY / GROUP BY allow one;
#   2. a name two contexts of one level hold: 42702 "Ambiguous field name
#      between table A and table B [and table C]" - the contexts in the
#      order the engine PUSHES them (a JOIN hands its sides back reversed,
#      a RIGHT / FULL join the right side first), a relation named by its
#      table even when aliased, a view as a view;
#   3. a sort / group POSITION outside the select list, `*` counted;
#   4. the aggregate laws in pass1_rse_impl's order: an aggregate or
#      window in the WHERE / GROUP BY, nested aggregates, a column neither
#      grouped nor aggregated in the select list / ORDER BY / HAVING, SUM /
#      AVG of a non-number (after every -206, at the describe);
#   5. the parser's COUNT(DISTINCT *) and a signed NTILE count;
#   6. an INSERT's 21S01 count and -206 names (VALUES first), an UPDATE /
#      DELETE's -206; a literal the column cannot take is 22018
#      "conversion error from string ..." / 22003 / 22001 at EXECUTE
#      (a PREPARE refusal before), the first in VALUES order; a drawn
#      sequence value past its column is 22003, the draw kept;
#   7. DDL the catalog refuses at EXECUTE: a column named twice (23000,
#      RDB$INDEX_72 and its key), a second PRIMARY KEY (42S11, refused bare
#      at prepare before), DROP DOMAIN of a used domain (DYN 43, the local
#      name), CREATE INDEX over a missing column (DYN 120);
#   8. functions: DATEADD / DATEDIFF's part errors at EXECUTE per row
#      (refused at prepare before, NULL answering NULL), HY004 "Datatypes
#      are not comparable in expression COALESCE|CASE|DECODE|MAXVALUE"
#      (IIF named CASE), the select list evaluated RIGHT TO LEFT so the LAST
#      failing item names the error, ABS of the INT128 minimum the
#      integer-overflow message, NTILE(0) / LAG(-1) at the fetch;
#   9. the "Problematic key value" as DescPrinter prints it: no DATE word,
#      no quote doubling, a CHAR's pad trimmed, DOUBLE `%#.16g`, FLOAT
#      `%#.8g`.
#
# RECORDED, not fixed (section 10 - refusals, never a wrong answer): a
# window over an aggregate, COALESCE of a DATE and a text, DATEADD
# (WEEKDAY), a UNION of incomparable types (HY004 "UNION"), a numeric
# string past 22 characters (the engine's truncation), an UPDATE's
# unconvertible literal (the engine raises per row at EXECUTE, so it
# answers an empty table - this server refuses the prepare), and the tie
# order of a UNION ALL under ORDER BY (both orders are a correct answer
# to the query; the engine's is an artifact of its sort).
#
# Usage: qa/serve-real-errvec.sh [port]   (default 6010)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-6010}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/errvec-eng.fdb"; FC="$D/errvec-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T1 (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, B BIGINT, N NUMERIC(10,2), V VARCHAR(20), D DATE, F DOUBLE PRECISION, BO BOOLEAN);
CREATE TABLE T2 (ID INTEGER NOT NULL PRIMARY KEY, T1ID INTEGER, X INTEGER, S VARCHAR(20));
CREATE TABLE T3 (K INTEGER, NAME VARCHAR(10));
CREATE TABLE E (ID INTEGER);
CREATE VIEW VT2 AS SELECT ID, X FROM T2;
INSERT INTO T1 VALUES (1, 10, 100, 1.50, 'apple', DATE '2020-01-01', 1.5, TRUE);
INSERT INTO T1 VALUES (2, 20, NULL, 2.25, 'banana', DATE '2021-06-15', NULL, FALSE);
INSERT INTO T1 VALUES (3, NULL, 300, NULL, 'cherry', NULL, 3.25, NULL);
INSERT INTO T2 VALUES (1, 1, 5, 'one');
INSERT INTO T2 VALUES (2, 1, 6, 'two');
INSERT INTO T2 VALUES (3, 2, NULL, 'three');
INSERT INTO T3 VALUES (1, 'x');
CREATE TABLE W (ID INTEGER, GRP VARCHAR(5), VAL INTEGER);
INSERT INTO W VALUES (1, 'A', 10);
INSERT INTO W VALUES (2, 'A', 20);
CREATE TABLE WE (ID INTEGER, VAL INTEGER);
CREATE TABLE TS (S SMALLINT, V VARCHAR(3), B BOOLEAN, D DATE);
CREATE SEQUENCE SM;
CREATE TABLE TP (ID INTEGER PRIMARY KEY, NAME VARCHAR(20) UNIQUE);
CREATE DOMAIN D_POS INTEGER;
CREATE DOMAIN D_FREE INTEGER;
CREATE TABLE TDOM (P D_POS);
CREATE TABLE KX (D DATE, V VARCHAR(10), F DOUBLE PRECISION, C CHAR(3), W FLOAT, CONSTRAINT KX_UQ UNIQUE (D, V, F, C, W));
CREATE TABLE KW (F DOUBLE PRECISION PRIMARY KEY);
CREATE TABLE KZ (V VARCHAR(5) PRIMARY KEY);
COMMIT;
INSERT INTO KX VALUES (DATE '2020-01-02', 'it''s', 1.25e-5, 'ab', 3.14);
INSERT INTO KW VALUES (1.5);
INSERT INTO KW VALUES (-2e300);
INSERT INTO KZ VALUES ('a  ');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/errvec-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/errvec-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/errvec-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
# the two-phase rig (qa/ddlphase.c): PREPARE, EXECUTE and COMMIT each
# statement on its own and say which phase raised
RIG="$D/errvec-ddlphase"
if ! cc -o "$RIG" "$(dirname "$0")/ddlphase.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "FAIL cannot build the phase rig (cc/libfbclient missing)"; exit 1
fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-errvec-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC" "$RIG"' EXIT
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
# the phase rig over one statement: PREPARED|EXECUTED|COMMITTED, or the
# phase that raised and its vector
phase() { timeout 25 "$RIG" "$1" "$2" 2>&1 | tr -d '\r' | sed 's/  */ /g' | paste -sd'|'; }
# the engine's output pinned, and this server's equal to it
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the phase rig, pinned on both sides
ppin() { # <label> <sql> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(phase "127.0.0.1/$REAL:$ENG" "$2"); fv=$(phase "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# RECORDED: this server REFUSES (a clean error, never a wrong value) where
# the engine answers or raises something else. Fails the day the two
# agree, so the cell gets promoted.
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "${fv#*Statement failed}" = "$fv" ]; then
        echo "FAIL $1 - this server neither agrees nor refuses"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: the engine [${ev:0:70}], this server refuses)"; fi
}
# RECORDED DIVERGENCE: both sides pinned; fails when either moves
differs() { # <label> <script> <engine-output> <fc-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - THIS SERVER MOVED: [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded divergence: engine [$ev], this server [$fv])"; fi
}

echo '--- 1. A BARE NAME NO CONTEXT HOLDS IS -206 "Column unknown" (42S22) AT ITS PLACE, IN THE ENGINE'\''S PASS ORDER'
pin '1 a bare unknown select item' 'SELECT NOSUCH FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 8'
pin '1 the second select item' 'SELECT ID, NOSUCH FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 12'
pin '1 in the WHERE' 'SELECT ID FROM T1 WHERE NOSUCH = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 25'
pin '1 in the ORDER BY' 'SELECT ID FROM T1 ORDER BY NOSUCH;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 28'
pin '1 in the GROUP BY' 'SELECT ID FROM T1 GROUP BY NOSUCH;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 28'
pin '1 in the HAVING' 'SELECT ID, COUNT(*) FROM T1 GROUP BY ID HAVING NOSUCH > 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 48'
pin '1 inside a call' 'SELECT UPPER(NOSUCH) FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 14'
pin '1 an arithmetic operand' 'SELECT ID + NOSUCH FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 13'
pin '1 a quoted name keeps its case' 'SELECT "nosuch" FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"nosuch"|-At line 1, column 8'
pin '1 over RDB$DATABASE' 'SELECT NOSUCH FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 8'
pin '1 the right side of a comparison, beside an alias' 'SELECT ID FROM T1 T WHERE T.ID = NOSUCH;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 34'
pin '1 two unknowns: the first select item' 'SELECT NOSUCH, NOSUCH2 FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 8'
pin '1 an AND passes its RIGHT operand first' 'SELECT ID FROM T1 WHERE NOSUCH2 = 1 AND NOSUCH = 2;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 41'
pin '1 on the second line' 'SELECT ID,
  NOSUCH FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 2, column 3'
pin '1 the WHERE before the select list' 'SELECT NOSUCH2 FROM T1 WHERE NOSUCH = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 30'
pin '1 a non-reserved word is a name too' 'SELECT NAME FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NAME"|-At line 1, column 8'
pin '1 an alias is no column in the WHERE' 'SELECT ID X FROM T1 WHERE X = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"X"|-At line 1, column 27'
pin '1 ...nor in the HAVING' 'SELECT A FROM T1 GROUP BY A HAVING X > 0;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"X"|-At line 1, column 36'
pin '1 inside a subquery' 'SELECT (SELECT NOSUCH FROM T2) FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 16'
pin '1 an aggregate'\''s argument' 'SELECT SUM(NOSUCH) FROM W;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 12'
pin '1 a window'\''s ORDER BY' 'SELECT ID, ROW_NUMBER() OVER (ORDER BY NOSUCH) FROM W;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 40'
pin '1 control: an alias in the ORDER BY answers' 'SELECT ID X FROM T1 ORDER BY X;' 'X|1|2|3'
pin '1 control: an alias in the GROUP BY answers' 'SELECT A X, COUNT(*) FROM T1 GROUP BY X ORDER BY 1;' 'X COUNT|<null> 1|10 1|20 1'
pin '1 control: NAME where a relation holds it' 'SELECT NAME FROM T3;' 'NAME|x'
pin '1 control: a correlated outer column' 'SELECT ID, (SELECT COUNT(*) FROM T2 WHERE T1ID = T1.ID AND ID = T1.ID) FROM T1 ORDER BY ID;' 'ID COUNT|1 1|2 0|3 0'
echo '--- 2. A NAME TWO CONTEXTS HOLD IS 42702, THE CONTEXTS IN THE ORDER THE ENGINE PUSHED THEM'
pin '2 JOIN: the right side first' 'SELECT ID FROM T1 JOIN T2 ON T1.ID = T2.T1ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T2" and table "PUBLIC"."T1"|-ID'
pin '2 aliases do not rename the relations' 'SELECT ID FROM T1 A JOIN T2 B ON A.ID = B.ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T2" and table "PUBLIC"."T1"|-ID'
pin '2 a comma list: FROM order' 'SELECT ID FROM T1, T2;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '2 three items, one message' 'SELECT ID FROM T1, T2, E;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2" and table "PUBLIC"."E"|-ID'
pin '2 a relation twice' 'SELECT K FROM T3, T3 X;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T3" and table "PUBLIC"."T3"|-K'
pin '2 in the WHERE' 'SELECT T1.ID FROM T1, T2 WHERE ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '2 a JOIN chain' 'SELECT ID FROM T1 JOIN T2 ON T1.ID = T2.ID JOIN E ON E.ID = T1.ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."E" and table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '2 a RIGHT JOIN keeps the left first' 'SELECT ID FROM T1 RIGHT JOIN T2 ON 1 = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '2 a FULL JOIN under a JOIN' 'SELECT ID FROM T1 FULL JOIN T2 ON 1 = 1 JOIN E ON 1 = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."E" and table "PUBLIC"."T2" and table "PUBLIC"."T1"|-ID'
pin '2 a view is named a view' 'SELECT ID FROM T1, VT2;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and view "PUBLIC"."VT2"|-ID'
pin '2 control: qualified, it answers' 'SELECT T1.ID FROM T1 JOIN T2 ON T1.ID = T2.T1ID ORDER BY 1;' 'ID|1|1|2'
echo '--- 3. A SORT OR GROUP POSITION OUTSIDE THE SELECT LIST'
pin '3 ORDER BY 3 of one item' 'SELECT ID FROM T1 ORDER BY 3;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
pin '3 ORDER BY 0' 'SELECT ID FROM T1 ORDER BY 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
pin '3 control: a SIGNED number is an expression, not a position' 'SELECT ID FROM T1 ORDER BY -1;' 'ID|1|2|3'
pin '3 the second key' 'SELECT ID, A FROM T1 ORDER BY 1, 5;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
pin '3 SELECT * counts its columns' 'SELECT * FROM T1 ORDER BY 9;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
pin '3 GROUP BY 0' 'SELECT ID FROM T1 GROUP BY 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the GROUP BY clause'
pin '3 GROUP BY 2 of one item' 'SELECT ID FROM T1 GROUP BY 2;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the GROUP BY clause'
pin '3 a GROUP BY position naming an aggregate' 'SELECT COUNT(*) FROM W GROUP BY 1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a GROUP BY clause'
pin '3 ...the second item'\''s' 'SELECT GRP, COUNT(*) FROM W GROUP BY 2;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a GROUP BY clause'
pin '3 an ORDER BY position after a GROUP BY' 'SELECT GRP FROM W GROUP BY GRP ORDER BY 2;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
pin '3 the -206 of the select list comes first' 'SELECT NOSUCH FROM T1 ORDER BY 3;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 8'
pin '3 control: SELECT * ORDER BY 8' 'SELECT ID FROM (SELECT * FROM T1 ORDER BY 8 NULLS FIRST, 1);' 'ID|3|2|1'
pin '3 control: GROUP BY 1' 'SELECT A, COUNT(*) FROM T1 GROUP BY 1 ORDER BY 1 NULLS FIRST;' 'A COUNT|<null> 1|10 1|20 1'
echo '--- 4. THE AGGREGATE LAWS, IN pass1_rse_impl'\''s ORDER'
pin '4 a column neither grouped nor aggregated' 'SELECT GRP, COUNT(*) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '4 ...beside a GROUP BY' 'SELECT ID, SUM(VAL) FROM W GROUP BY GRP;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '4 ...with a HAVING' 'SELECT GRP, VAL FROM W GROUP BY GRP HAVING COUNT(*) > 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '4 nested aggregates' 'SELECT SUM(SUM(VAL)) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Nested aggregate and window functions are not allowed'
pin '4 MAX(MIN(..))' 'SELECT MAX(MIN(VAL)) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Nested aggregate and window functions are not allowed'
pin '4 items in turn: the nested one first' 'SELECT SUM(SUM(VAL)), GRP FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Nested aggregate and window functions are not allowed'
pin '4 items in turn: the invalid one first' 'SELECT GRP, SUM(SUM(VAL)) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '4 an aggregate in the WHERE' 'SELECT ID FROM W WHERE SUM(VAL) > 1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a WHERE clause, use HAVING (for aggregate only) instead'
pin '4 COUNT(*) in the WHERE' 'SELECT ID FROM W WHERE COUNT(*) > 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a WHERE clause, use HAVING (for aggregate only) instead'
pin '4 a window function in the WHERE' 'SELECT ID FROM W WHERE ROW_NUMBER() OVER (ORDER BY ID) > 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a WHERE clause, use HAVING (for aggregate only) instead'
pin '4 an aggregate in the GROUP BY' 'SELECT COUNT(*) FROM W GROUP BY SUM(VAL);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a GROUP BY clause'
pin '4 a window function in the GROUP BY' 'SELECT ID FROM W GROUP BY ROW_NUMBER() OVER (ORDER BY ID);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a GROUP BY clause'
pin '4 an invalid ORDER BY' 'SELECT GRP, SUM(VAL) FROM W GROUP BY GRP ORDER BY ID;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the ORDER BY clause (not contained in either an aggregate function or the GROUP BY clause)'
pin '4 an invalid HAVING' 'SELECT GRP, SUM(VAL) FROM W GROUP BY GRP HAVING ID > 1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the HAVING clause (neither an aggregate function nor a part of the GROUP BY clause)'
pin '4 the HAVING'\''s -206 before its judgement' 'SELECT GRP, SUM(VAL) FROM W GROUP BY GRP HAVING NOSUCH > 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 49'
pin '4 SUM of a text column' 'SELECT SUM(GRP) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '4 AVG of a text column' 'SELECT AVG(GRP) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for AVG in dialect 3 must be numeric'
pin '4 SUM of a string literal' 'SELECT SUM('\''a'\'') FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '4 AVG of a CAST to text' 'SELECT AVG(CAST('\''1'\'' AS VARCHAR(5))) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for AVG in dialect 3 must be numeric'
pin '4 SUM of a DATE' 'SELECT SUM(D) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '4 AVG of a BOOLEAN' 'SELECT AVG(BO) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for AVG in dialect 3 must be numeric'
pin '4 SUM(DISTINCT text)' 'SELECT SUM(DISTINCT V) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '4 a windowed SUM of text' 'SELECT SUM(V) OVER () FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '4 the -206 of an ORDER BY before the SUM'\''s type' 'SELECT SUM(GRP) FROM W ORDER BY NOSUCH;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 33'
pin '4 control: SUM of a number' 'SELECT SUM(VAL), COUNT(*) FROM W;' 'SUM COUNT|30 2'
pin '4 control: the grouped item' 'SELECT GRP, SUM(VAL) FROM W GROUP BY GRP;' 'GRP SUM|A 30'
pin '4 control: an expression equal to the key' 'SELECT VAL + 1, COUNT(*) FROM W GROUP BY VAL + 1 ORDER BY 1;' 'ADD COUNT|11 1|21 1'
echo '--- 5. THE PARSER'\''S OWN'
pin '5 COUNT(DISTINCT *)' 'SELECT COUNT(DISTINCT *) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 23|-*'
pin '5 COUNT(ALL *)' 'SELECT COUNT(ALL *) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 18|-*'
pin '5 a signed NTILE count' 'SELECT ID, NTILE(-1) OVER (ORDER BY ID) FROM W;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 18|--'
echo '--- 6. DML: THE COUNT, THE NAMES, AND A LITERAL THE COLUMN CANNOT TAKE (22018 / 22003 AT EXECUTE)'
pin '6 VALUES shorter than the table' 'INSERT INTO TP VALUES (9); ROLLBACK;' 'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values'
pin '6 VALUES longer than the table' 'INSERT INTO TP VALUES (9, '\''a'\'', 3); ROLLBACK;' 'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values'
pin '6 VALUES longer than the list' 'INSERT INTO TP (ID) VALUES (1, 2); ROLLBACK;' 'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values'
pin '6 a list shorter than VALUES' 'INSERT INTO TP (ID, NAME) VALUES (1); ROLLBACK;' 'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values'
pin '6 an unknown list column' 'INSERT INTO TP (NOSUCH) VALUES (1); ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 17'
pin '6 ...the list before the count' 'INSERT INTO TP (NOSUCH) VALUES (1, 2); ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 17'
pin '6 ...the second list column' 'INSERT INTO TP (ID, NOSUCH, NAME) VALUES (1, 2, 3); ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 21'
pin '6 a bare name in VALUES' 'INSERT INTO TP (ID, NAME) VALUES (1, NOSUCH); ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 38'
pin '6 an UPDATE'\''s target column' 'UPDATE TP SET NOSUCH = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 15'
pin '6 an UPDATE'\''s target before its value' 'UPDATE TP SET NOSUCH = NOSUCH2; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 15'
pin '6 an UPDATE'\''s WHERE before its SET' 'UPDATE TP SET NAME = NOSUCH WHERE NOSUCH2 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH2"|-At line 1, column 35'
pin '6 a DELETE'\''s WHERE' 'DELETE FROM TP WHERE NOSUCH = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 22'
ppin '6 phase: the count is a PREPARE refusal' 'INSERT INTO TP VALUES (9)' 'PREPARE ERR: |Dynamic SQL Error |SQL error code = -804 |Count of read-write columns does not equal count of values'
ppin '6 phase: the list column too' 'INSERT INTO TP (NOSUCH) VALUES (1)' 'PREPARE ERR: |Dynamic SQL Error |SQL error code = -206 |Column unknown |"NOSUCH" |At line 1, column 17'
ppin '6 phase: '\''x'\'' into a SMALLINT fails at EXECUTE' 'INSERT INTO TS (S) VALUES ('\''x'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "x"'
ppin '6 phase: '\''1x'\''' 'INSERT INTO TS (S) VALUES ('\''1x'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "1x"'
ppin '6 phase: an empty string' 'INSERT INTO TS (S) VALUES ('\'''\'')' 'PREPARED|EXECUTE ERR: |conversion error from string ""'
ppin '6 phase: 12345 into a VARCHAR(3) is a conversion error' 'INSERT INTO TS (V) VALUES (12345)' 'PREPARED|EXECUTE ERR: |conversion error from string "12345"'
ppin '6 phase: 12.5 into a VARCHAR(3)' 'INSERT INTO TS (V) VALUES (12.5)' 'PREPARED|EXECUTE ERR: |conversion error from string "12.5"'
ppin '6 phase: '\''yes'\'' into a BOOLEAN' 'INSERT INTO TS (B) VALUES ('\''yes'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "yes"'
ppin '6 phase: 1 into a BOOLEAN' 'INSERT INTO TS (B) VALUES (1)' 'PREPARED|EXECUTE ERR: |conversion error from string "1"'
ppin '6 phase: '\''2020-13-01'\'' into a DATE' 'INSERT INTO TS (D) VALUES ('\''2020-13-01'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "2020-13-01"'
ppin '6 phase: 12 into a DATE' 'INSERT INTO TS (D) VALUES (12)' 'PREPARED|EXECUTE ERR: |conversion error from string "12"'
ppin '6 phase: 1.5 into a DATE' 'INSERT INTO TS (D) VALUES (1.5)' 'PREPARED|EXECUTE ERR: |conversion error from string "1.5"'
ppin '6 phase: '\'''\'' into a DATE' 'INSERT INTO TS (D) VALUES ('\'''\'')' 'PREPARED|EXECUTE ERR: |conversion error from string ""'
ppin '6 phase: TRUE into a SMALLINT is "BOOLEAN"' 'INSERT INTO TS (S) VALUES (TRUE)' 'PREPARED|EXECUTE ERR: |conversion error from string "BOOLEAN"'
ppin '6 phase: TRUE into a DATE' 'INSERT INTO TS (D) VALUES (TRUE)' 'PREPARED|EXECUTE ERR: |conversion error from string "BOOLEAN"'
ppin '6 phase: the VALUES order names the first (S, D)' 'INSERT INTO TS (S, D) VALUES ('\''x'\'', '\''y'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "x"'
ppin '6 phase: ...and (D, S)' 'INSERT INTO TS (D, S) VALUES ('\''y'\'', '\''x'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "y"'
ppin '6 phase: a conversion before a truncation' 'INSERT INTO TS (S, V) VALUES ('\''x'\'', '\''abcde'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "x"'
ppin '6 phase: '\''70000'\'' into a SMALLINT is 22003' 'INSERT INTO TS (S) VALUES ('\''70000'\'')' 'PREPARED|EXECUTE ERR: |arithmetic exception, numeric overflow, or string truncation |numeric value is out of range'
ppin '6 phase: '\''-40000'\''' 'INSERT INTO TS (S) VALUES ('\''-40000'\'')' 'PREPARED|EXECUTE ERR: |arithmetic exception, numeric overflow, or string truncation |numeric value is out of range'
ppin '6 phase: 70000' 'INSERT INTO TS (S) VALUES (70000)' 'PREPARED|EXECUTE ERR: |arithmetic exception, numeric overflow, or string truncation |numeric value is out of range'
ppin '6 phase: a truncation' 'INSERT INTO TS (V) VALUES ('\''abcd'\'')' 'PREPARED|EXECUTE ERR: |arithmetic exception, numeric overflow, or string truncation |string right truncation |expected length 3, actual 4'
ppin '6 phase: a drawn value past SMALLINT' 'INSERT INTO TS (S) VALUES (GEN_ID(SM, 100000))' 'PREPARED|EXECUTE ERR: |arithmetic exception, numeric overflow, or string truncation |numeric value is out of range'
pin '6 ...the draw stands' 'SELECT GEN_ID(SM, 0) FROM RDB$DATABASE;' 'GEN_ID|100000'
pin '6 nothing was stored' 'SELECT COUNT(*) FROM TS;' 'COUNT|0'
pin '6 control: '\'' 12 '\'' and '\''1e3'\'' store' 'INSERT INTO TS (S) VALUES ('\'' 12 '\''); INSERT INTO TS (S) VALUES ('\''1e3'\''); SELECT S FROM TS ORDER BY S; ROLLBACK;' 'S|12|1000'
pin '6 control: '\''true'\'' and '\'' TRUE '\'' store' 'INSERT INTO TS (B) VALUES ('\''true'\''); INSERT INTO TS (B) VALUES ('\'' TRUE '\''); SELECT B FROM TS; ROLLBACK;' 'B|<true>|<true>'
pin '6 control: 1.5 into a VARCHAR(3)' 'INSERT INTO TS (V) VALUES (1.5); SELECT V FROM TS; ROLLBACK;' 'V|1.5'
echo '--- 7. DDL THE CATALOG REFUSES AT EXECUTE'
ppin '7 a column named twice' 'CREATE TABLE TBIG (A INTEGER, A INTEGER)' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE TABLE "PUBLIC"."TBIG" failed |violation of PRIMARY or UNIQUE KEY constraint "RDB$INDEX_72" on table "SYSTEM"."RDB$RELATION_FIELDS" |Problematic key value is ("RDB$FIELD_NAME" = '\''A'\'', "RDB$SCHEMA_NAME" = '\''PUBLIC'\'', "RDB$PACKAGE_NAME" = NULL, "RDB$RELATION_NAME" = '\''TBIG'\'')'
ppin '7 ...quoted' 'CREATE TABLE TBIG2 ("a" INTEGER, B INTEGER, "a" INTEGER)' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE TABLE "PUBLIC"."TBIG2" failed |violation of PRIMARY or UNIQUE KEY constraint "RDB$INDEX_72" on table "SYSTEM"."RDB$RELATION_FIELDS" |Problematic key value is ("RDB$FIELD_NAME" = '\''a'\'', "RDB$SCHEMA_NAME" = '\''PUBLIC'\'', "RDB$PACKAGE_NAME" = NULL, "RDB$RELATION_NAME" = '\''TBIG2'\'')'
ppin '7 two column-level PRIMARY KEYs' 'CREATE TABLE TPK2 (A INTEGER PRIMARY KEY, B INTEGER PRIMARY KEY)' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE TABLE "PUBLIC"."TPK2" failed |Attempt to define a second PRIMARY KEY for the same table'
ppin '7 a column-level and a table-level one' 'CREATE TABLE TPK3 (A INTEGER PRIMARY KEY, B INTEGER, PRIMARY KEY (B))' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE TABLE "PUBLIC"."TPK3" failed |Attempt to define a second PRIMARY KEY for the same table'
ppin '7 two named ones' 'CREATE TABLE TPK4 (A INTEGER NOT NULL, B INTEGER NOT NULL, CONSTRAINT P1 PRIMARY KEY (A), CONSTRAINT P2 PRIMARY KEY (B))' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE TABLE "PUBLIC"."TPK4" failed |Attempt to define a second PRIMARY KEY for the same table'
ppin '7 DROP DOMAIN of a used domain' 'DROP DOMAIN D_POS' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |DROP DOMAIN "PUBLIC"."D_POS" failed |Domain "PUBLIC"."D_POS" is used in table "PUBLIC"."TDOM" (local name "P") and cannot be dropped'
ppin '7 CREATE INDEX over a missing column' 'CREATE INDEX TP_N ON TP (NOSUCH)' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE INDEX "PUBLIC"."TP_N" failed |Unknown columns in index "PUBLIC"."TP_N"'
ppin '7 ...the second column missing' 'CREATE INDEX TP_N2 ON TP (ID, NOSUCH)' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE INDEX "PUBLIC"."TP_N2" failed |Unknown columns in index "PUBLIC"."TP_N2"'
pin '7 none of them was written' 'SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME IN ('\''TBIG'\'', '\''TBIG2'\'', '\''TPK2'\'', '\''TPK3'\'', '\''TPK4'\''); SELECT COUNT(*) FROM RDB$INDICES WHERE RDB$INDEX_NAME IN ('\''TP_N'\'', '\''TP_N2'\''); SELECT COUNT(*) FROM RDB$FIELDS WHERE RDB$FIELD_NAME = '\''D_POS'\'';' 'COUNT|0|COUNT|0|COUNT|1'
pin '7 the isql vector of the duplicate column' 'CREATE TABLE TBIG (A INTEGER, A INTEGER);' 'Statement failed, SQLSTATE = 23000|unsuccessful metadata update|-CREATE TABLE "PUBLIC"."TBIG" failed|-violation of PRIMARY or UNIQUE KEY constraint "RDB$INDEX_72" on table "SYSTEM"."RDB$RELATION_FIELDS"|-Problematic key value is ("RDB$FIELD_NAME" = '\''A'\'', "RDB$SCHEMA_NAME" = '\''PUBLIC'\'', "RDB$PACKAGE_NAME" = NULL, "RDB$RELATION_NAME" = '\''TBIG'\'')'
pin '7 the isql vector of a second PRIMARY KEY' 'CREATE TABLE TPK2 (A INTEGER PRIMARY KEY, B INTEGER PRIMARY KEY);' 'Statement failed, SQLSTATE = 42S11|unsuccessful metadata update|-CREATE TABLE "PUBLIC"."TPK2" failed|-Attempt to define a second PRIMARY KEY for the same table'
pin '7 control: an unused domain drops' 'DROP DOMAIN D_FREE; COMMIT; SELECT COUNT(*) FROM RDB$FIELDS WHERE RDB$FIELD_NAME = '\''D_FREE'\'';' 'COUNT|0'
echo '--- 8. FUNCTIONS: DATEADD / DATEDIFF RAISE PER ROW, CONDITIONALS OVER INCOMPARABLE TYPES, THE LAST ITEM'\''S ERROR'
pin '8 DATEADD(DAY) to a TIME' 'SELECT DATEADD(DAY, 1, TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 DATEADD(MONTH) to a TIME' 'SELECT DATEADD(MONTH, 1, TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 DATEADD(WEEK) to a TIME' 'SELECT DATEADD(WEEK, 1, TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 the TO form' 'SELECT DATEADD(-1 DAY TO TIME '\''10:00:00'\''), 1 FROM RDB$DATABASE;' 'DATEADD CONSTANT|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 a zoned TIME' 'SELECT DATEADD(DAY, 1, TIME '\''10:00:00 +02:00'\'') FROM RDB$DATABASE;' 'DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 under an arithmetic' 'SELECT DATEADD(DAY, 1, TIME '\''10:00:00'\'') + 0 FROM RDB$DATABASE;' 'ADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 in a WHERE' 'SELECT ID FROM T1 WHERE DATEADD(DAY, 1, TIME '\''10:00:00'\'') IS NULL;' 'ID|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Only HOUR, MINUTE, SECOND and MILLISECOND can be added to TIME values in DATEADD'
pin '8 a NULL TIME answers NULL' 'SELECT DATEADD(DAY, 1, CAST(NULL AS TIME)) FROM RDB$DATABASE;' 'DATEADD|<null>'
pin '8 a NULL amount answers NULL' 'SELECT DATEADD(DAY, NULL, TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEADD|<null>'
pin '8 no row, no error' 'SELECT DATEADD(DAY, 1, CAST('\''10:00:00'\'' AS TIME)) FROM T1 WHERE 1 = 0;' ''
pin '8 DATEDIFF(DAY) of two TIMEs' 'SELECT DATEDIFF(DAY, TIME '\''10:00:00'\'', TIME '\''11:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of TIME-<value> in DATEDIFF cannot be expressed in YEAR, MONTH, DAY or WEEK'
pin '8 DATEDIFF(WEEK)' 'SELECT DATEDIFF(WEEK, TIME '\''10:00:00'\'', TIME '\''11:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of TIME-<value> in DATEDIFF cannot be expressed in YEAR, MONTH, DAY or WEEK'
pin '8 DATEDIFF(MONTH)' 'SELECT DATEDIFF(MONTH, TIME '\''10:00:00'\'', TIME '\''11:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of TIME-<value> in DATEDIFF cannot be expressed in YEAR, MONTH, DAY or WEEK'
pin '8 DATEDIFF(DAY) of a TIME and a TIMESTAMP' 'SELECT DATEDIFF(DAY, TIME '\''10:00:00'\'', TIMESTAMP '\''2020-01-01 10:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of TIME-<value> in DATEDIFF cannot be expressed in YEAR, MONTH, DAY or WEEK'
pin '8 DATEDIFF(HOUR) of a DATE and a TIME' 'SELECT DATEDIFF(HOUR, DATE '\''2020-01-01'\'', TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of DATE-TIME or TIME-DATE in DATEDIFF cannot be expressed in HOUR, MINUTE, SECOND and MILLISECOND'
pin '8 ...a TIME and a DATE' 'SELECT DATEDIFF(HOUR, TIME '\''10:00:00'\'', DATE '\''2020-01-01'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of DATE-TIME or TIME-DATE in DATEDIFF cannot be expressed in HOUR, MINUTE, SECOND and MILLISECOND'
pin '8 ...MILLISECOND' 'SELECT DATEDIFF(MILLISECOND, DATE '\''2020-01-01'\'', TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of DATE-TIME or TIME-DATE in DATEDIFF cannot be expressed in HOUR, MINUTE, SECOND and MILLISECOND'
pin '8 DATEDIFF(HOUR) of a TIMESTAMP and a TIME' 'SELECT DATEDIFF(HOUR, TIMESTAMP '\''2020-01-01 10:00:00'\'', TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of TIME-TIMESTAMP or TIMESTAMP-TIME in DATEDIFF cannot be expressed in HOUR, MINUTE, SECOND or MILLISECOND'
pin '8 the FROM .. TO form' 'SELECT DATEDIFF(DAY FROM TIME '\''10:00:00'\'' TO TIME '\''11:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-The result of TIME-<value> in DATEDIFF cannot be expressed in YEAR, MONTH, DAY or WEEK'
pin '8 a NULL side answers NULL' 'SELECT DATEDIFF(DAY, CAST(NULL AS TIME), TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|<null>'
pin '8 control: DATEADD(HOUR) to a DATE' 'SELECT DATEADD(HOUR, 1, DATE '\''2020-01-01'\'') FROM RDB$DATABASE;' 'DATEADD|2020-01-01'
pin '8 control: DATEDIFF(HOUR) of two DATEs' 'SELECT DATEDIFF(HOUR, DATE '\''2020-01-01'\'', DATE '\''2020-01-02'\'') FROM RDB$DATABASE;' 'DATEDIFF|24'
pin '8 control: DATEDIFF(MINUTE) of two TIMEs' 'SELECT DATEDIFF(MINUTE, TIME '\''10:00:00'\'', TIME '\''11:30:00'\'') FROM RDB$DATABASE;' 'DATEDIFF|90'
pin '8 COALESCE(DATE, TIMESTAMP)' 'SELECT COALESCE(DATE '\''2024-01-01'\'', TIMESTAMP '\''2024-01-01 00:00:00'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 COALESCE(TIMESTAMP, DATE)' 'SELECT COALESCE(TIMESTAMP '\''2024-01-01 00:00:00'\'', DATE '\''2024-01-01'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 COALESCE(DATE, TIME)' 'SELECT COALESCE(DATE '\''2024-01-01'\'', TIME '\''10:00:00'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 a NULL takes no part' 'SELECT COALESCE(NULL, DATE '\''2024-01-01'\'', TIMESTAMP '\''2024-01-01 00:00:00'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 IIF is named CASE' 'SELECT IIF(1 = 1, DATE '\''2024-01-01'\'', TIMESTAMP '\''2024-01-01 00:00:00'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '8 a searched CASE' 'SELECT CASE WHEN 1 = 1 THEN DATE '\''2024-01-01'\'' ELSE TIMESTAMP '\''2024-01-01 00:00:00'\'' END FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '8 DECODE' 'SELECT DECODE(1, 1, DATE '\''2024-01-01'\'', TIMESTAMP '\''2024-01-01 00:00:00'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression DECODE'
pin '8 MAXVALUE' 'SELECT MAXVALUE(DATE '\''2024-01-01'\'', TIMESTAMP '\''2024-01-01 00:00:00'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression MAXVALUE'
pin '8 a DATE column beside CURRENT_TIMESTAMP' 'SELECT COALESCE(D, CURRENT_TIMESTAMP) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 a BOOLEAN beside a number' 'SELECT COALESCE(TRUE, 1) FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 a number beside a DATE' 'SELECT COALESCE(1, DATE '\''2024-01-01'\'') FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '8 control: NULLIF answers' 'SELECT NULLIF(DATE '\''2024-01-01'\'', TIMESTAMP '\''2024-01-01 00:00:00'\'') FROM RDB$DATABASE;' 'CASE|<null>'
pin '8 control: TIME beside TIME WITH TIME ZONE' 'SELECT COALESCE(TIME '\''10:00:00'\'', TIME '\''11:00:00 +02:00'\'') IS NOT NULL FROM RDB$DATABASE;' 'BOOL|<true>'
pin '8 the LAST failing item is named' 'SELECT LN(-7), SQRT(-2.5) FROM RDB$DATABASE;' 'LN SQRT|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for SQRT must be zero or positive'
pin '8 ...of three' 'SELECT LN(-8), LN(-7), SQRT(-2.5) FROM RDB$DATABASE;' 'LN LN SQRT|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for SQRT must be zero or positive'
pin '8 ...reversed' 'SELECT SQRT(-2.5), LN(-7) FROM RDB$DATABASE;' 'SQRT LN|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for LN must be positive'
pin '8 a division last' 'SELECT LN(-7), 1/0 FROM RDB$DATABASE;' 'LN DIVIDE|Statement failed, SQLSTATE = 22012|arithmetic exception, numeric overflow, or string truncation|-Integer divide by zero. The code attempted to divide an integer value by an integer divisor of zero.'
pin '8 a division first' 'SELECT 1/0, LN(-7) FROM RDB$DATABASE;' 'DIVIDE LN|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Argument for LN must be positive'
pin '8 ABS of the INT128 minimum' 'SELECT ABS(CAST(-170141183460469231731687303715884105728 AS INT128)) FROM RDB$DATABASE;' 'ABS|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.'
pin '8 control: ABS of the BIGINT minimum' 'SELECT ABS(CAST(-9223372036854775808 AS BIGINT)) FROM RDB$DATABASE;' 'ABS|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
pin '8 control: the INT128 minimum negated' 'SELECT -CAST(-170141183460469231731687303715884105728 AS INT128) FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.'
pin '8 control: two sequence draws, the right item first' 'SELECT GEN_ID(SM, 1), GEN_ID(SM, 1) FROM RDB$DATABASE;' 'GEN_ID GEN_ID|100002 100001'
pin '8 NTILE(0) at the fetch' 'SELECT ID, NTILE(0) OVER (ORDER BY ID) FROM W;' 'ID NTILE|Statement failed, SQLSTATE = 42000|Argument #1 for NTILE must be positive'
pin '8 NTILE(0) over no row' 'SELECT ID, NTILE(0) OVER (ORDER BY ID) FROM WE;' ''
pin '8 LAG with a negative offset' 'SELECT ID, LAG(VAL, -1) OVER (ORDER BY ID) FROM W;' 'ID LAG|Statement failed, SQLSTATE = 42000|Argument #2 for LAG must be zero or positive'
pin '8 LEAD with a negative offset' 'SELECT ID, LEAD(VAL, -2) OVER (ORDER BY ID) FROM W;' 'ID LEAD|Statement failed, SQLSTATE = 42000|Argument #2 for LEAD must be zero or positive'
pin '8 LAG(-1) over no row' 'SELECT ID, LAG(VAL, -1) OVER (ORDER BY ID) FROM WE;' ''
pin '8 control: NTILE(1), LAG(VAL, 0)' 'SELECT ID, NTILE(1) OVER (ORDER BY ID), LAG(VAL, 0) OVER (ORDER BY ID) FROM W;' 'ID NTILE LAG|1 1 10|2 1 20'
echo '--- 9. THE PROBLEMATIC KEY VALUE, AS DescPrinter PRINTS IT'
pin '9 DATE, a quote, DOUBLE, CHAR and FLOAT' 'INSERT INTO KX VALUES (DATE '\''2020-01-02'\'', '\''it'\'''\''s'\'', 1.25e-5, '\''ab'\'', 3.14);' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "KX_UQ" on table "PUBLIC"."KX"|-Problematic key value is ("D" = '\''2020-01-02'\'', "V" = '\''it'\''s'\'', "F" = 1.250000000000000e-05, "C" = '\''ab'\'', "W" = 3.1400001)'
pin '9 a DOUBLE 1.5' 'INSERT INTO KW VALUES (1.5);' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_9" on table "PUBLIC"."KW"|-Problematic key value is ("F" = 1.500000000000000)'
pin '9 a DOUBLE -2e300' 'INSERT INTO KW VALUES (-2e300);' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_9" on table "PUBLIC"."KW"|-Problematic key value is ("F" = -2.000000000000000e+300)'
pin '9 control: a VARCHAR keeps its blanks' 'INSERT INTO KZ VALUES ('\''a  '\'');' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_11" on table "PUBLIC"."KZ"|-Problematic key value is ("V" = '\''a '\'')'
echo '--- 10. RECORDED - refusals this server keeps (never a wrong answer)'
refused '10 RECORDED a window over an aggregate' 'SELECT SUM(COUNT(*)) OVER () FROM W;' 'SUM|2'
refused '10 RECORDED text beside a DATE column in a COALESCE (the text wins)' 'SELECT COALESCE(D, '\''none'\'') FROM T1 ORDER BY ID;' 'COALESCE|2020-01-01|2021-06-15|none'
refused '10 RECORDED DATEADD(WEEKDAY) is the engine'\''s execute-time '\''Invalid part'\''' 'SELECT DATEADD(WEEKDAY, 1, DATE '\''2020-01-01'\'') FROM RDB$DATABASE;' 'DATEADD|Statement failed, SQLSTATE = 42000|expression evaluation not supported|-Invalid part WEEKDAY to be added to a DATE/TIME/TIMESTAMP value in DATEADD'
refused '10 RECORDED a UNION of a number and a DATE is HY004 '\''UNION'\''' 'SELECT ID FROM T1 UNION ALL SELECT D FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression UNION'
refused '10 RECORDED a numeric string past 22 characters is the engine'\''s truncation' 'INSERT INTO TS (S) VALUES ('\''99999999999999999999999'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 22, actual 23'
refused '10 RECORDED an UPDATE'\''s unconvertible literal: the engine raises per row at EXECUTE' 'INSERT INTO TS (S) VALUES (1); UPDATE TS SET S = '\''x'\''; ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "x"'
differs '10 RECORDED the tie order of a UNION ALL under ORDER BY' 'SELECT ID, V FROM T1 UNION ALL SELECT T1ID, S FROM T2 ORDER BY 1;' 'ID V|1 one|1 two|1 apple|2 three|2 banana|3 cherry' 'ID V|1 apple|1 one|1 two|2 banana|2 three|3 cherry'

ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-errvec-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
else echo "OK   no panic"; fi
echo "ran $ran checks"
if [ "$ran" -lt 194 ]; then echo "FAIL only $ran checks ran (floor 194)"; fail=1; fi
exit $fail
