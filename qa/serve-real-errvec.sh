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
#  11. the review of 1-9, each measured: an UPDATE resolves EVERY SET
#      target before its WHERE and its values; a JOIN's ON sees its own
#      join tree only, stacked in its own order (the 42702 lists, the
#      -206 of an earlier comma item); the grammar's own words after USING
#      / SUB_TYPE / MODE / HASH / ON OVERFLOW and KEY / IV are no column;
#      an aggregate's FILTER and WITHIN GROUP clauses are aggregated, and
#      LISTAGG is an aggregate; the implicit INSERT list leaves a COMPUTED
#      column out; a bare `*` beside another item is Token unknown; a
#      DECFLOAT literal's own pair of vectors. What the diagnosis cannot
#      name (the engine answers, or raises a 22009 zone error) stays the
#      BARE refusal - `bare` cells, which fail on any other vector.
#
#  12. the review of the merged binary, each measured: a refused
#      statement with multi-byte text a few bytes after a call (`ABS(1) =
#      'éé'`, OVERLAY, a CAST to a collated domain, FIRST_DAY) dropped the
#      attachment (08006, a slice inside a character) - it is the bare
#      refusal and the next statement answers; a non-ASCII literal next to
#      every diagnosis path (UTF8 cells: the -206 column counts BYTES); a
#      truncation into a NONE column counts its bytes, a NONE key value
#      prints its bytes; a GROUP BY / ORDER BY name is looked up in the
#      select list first (one item answers - the bare refusal here - two
#      are 42702 "between a field | an alias and a field | an alias in the
#      select list", in list order; an alias inside an expression is
#      -206); an alias glued to its item (`COUNT(*)X`, `'a'X`, `ID"X"`) is
#      no column; SUM / AVG of a non-number when its clause is remapped
#      (the select list's before its judgement and the HAVING, the ORDER
#      BY's before its own, the HAVING's after its -206); COALESCE /
#      DECODE / a simple CASE / MAXVALUE's HY004 as they are passed, a
#      searched CASE / IIF's once typed - inside an aggregate as the
#      aggregate's clause is remapped, beside its SUM / AVG law, and in a
#      FILTER late; two FROM items under one alias; a year 0 date is
#      22008, but a timestamp's time part is judged first (22018).
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
CREATE TABLE TC (A VARCHAR(5), B COMPUTED BY (A || 'x'));
CREATE TABLE TT (I INTEGER, TM TIME, TSP TIMESTAMP, DC DECFLOAT(16), DD DECFLOAT(34), DT DATE);
CREATE DOMAIN DCOLL AS VARCHAR(5) CHARACTER SET UTF8 COLLATE UNICODE_CI;
CREATE TABLE CU (ID INTEGER, U VARCHAR(10) CHARACTER SET UTF8, W VARCHAR(10) CHARACTER SET WIN1252);
CREATE TABLE LD (D DATE, TS TIMESTAMP);
CREATE TABLE KL (V VARCHAR(300) CHARACTER SET UTF8, B INTEGER, UNIQUE (V, B));
COMMIT;
INSERT INTO KX VALUES (DATE '2020-01-02', 'it''s', 1.25e-5, 'ab', 3.14);
INSERT INTO KW VALUES (1.5);
INSERT INTO KW VALUES (-2e300);
INSERT INTO KZ VALUES ('a  ');
INSERT INTO CU VALUES (1, 'abc', 'def');
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
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q ${CS:+-ch "$CS"} -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
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
# REFUSED BARE: where the diagnosis cannot name the engine's answer or
# vector, the refusal stays the bare `42000 / Dynamic SQL Error` - never a
# wrong vector. The engine's output pinned, this server's the bare one.
# A 4th argument is what the script's LATER statements answer on this
# server after the refusal - the attachment must live on.
bare() { # <label> <script> <engine-output> [<the rest of the script>]
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "$fv" != "Statement failed, SQLSTATE = 42000|Dynamic SQL Error${4:+|$4}" ]; then
        echo "FAIL $1 - not the bare refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (bare refusal; the engine [${ev:0:70}])"; fi
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
echo '--- 11. THE REVIEW OF THE DIAGNOSIS: UPDATE TARGETS FIRST, AN ON'\''S OWN SCOPE, THE GRAMMAR'\''S WORDS, FILTER / WITHIN GROUP, COMPUTED COLUMNS, THE LITERALS'
pin '11 UPDATE: every SET target first, then the WHERE' 'UPDATE T3 SET NOPE1 = NOPE2 WHERE NOPE3 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE1"|-At line 1, column 15'
pin '11 UPDATE: a target before the WHERE' 'UPDATE T3 SET NOPE1 = 1 WHERE NOPE3 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE1"|-At line 1, column 15'
pin '11 UPDATE: the second target before the first value' 'UPDATE T3 SET K = NOPE2, NOPE1 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE1"|-At line 1, column 26'
pin '11 UPDATE: the second target before the WHERE and the values' 'UPDATE T3 SET K = 1, NOPE1 = NOPE2 WHERE NOPE3 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE1"|-At line 1, column 22'
pin '11 UPDATE: valid targets - the WHERE before the values' 'UPDATE T3 SET K = NOPE2, NAME = NOPE5 WHERE NOPE3 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE3"|-At line 1, column 45'
pin '11 UPDATE: a qualified target first too' 'UPDATE T3 SET T3.NOPE1 = 1 WHERE T3.NOPE3 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"T3"."NOPE1"|-At line 1, column 15'
pin '11 UPDATE: an aliased target first too' 'UPDATE T3 X SET X.NOPE1 = X.NOPE2 WHERE X.NOPE3 = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"X"."NOPE1"|-At line 1, column 17'
pin '11 ON scope: a JOIN'\''s ON lists T1 then T2' 'SELECT T1.ID FROM T1 JOIN T2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '11 ON scope: a LEFT JOIN the same' 'SELECT ID FROM T1 LEFT JOIN T2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '11 ON scope: the ON before the select list' 'SELECT T1.ID FROM T1 JOIN T2 ON T1ID = ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '11 ON scope: the ON before the WHERE' 'SELECT 1 FROM T1 JOIN T2 ON ID = 1 WHERE NOPE = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '11 ON scope: a RIGHT JOIN lists T2 then T1' 'SELECT T1.ID FROM T1 RIGHT JOIN T2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T2" and table "PUBLIC"."T1"|-ID'
pin '11 ON scope: a FULL JOIN the same' 'SELECT T1.ID FROM T1 FULL JOIN T2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T2" and table "PUBLIC"."T1"|-ID'
pin '11 ON scope: an earlier comma item is not in it' 'SELECT T1.ID FROM T1, T2 JOIN VT2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T2" and view "PUBLIC"."VT2"|-ID'
pin '11 ON scope: the second ON sees the first join as it hands it back' 'SELECT T1.ID FROM T1 JOIN T2 ON 1=1 JOIN VT2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T2" and table "PUBLIC"."T1" and view "PUBLIC"."VT2"|-ID'
pin '11 ON scope: ...a RIGHT second join puts its side first' 'SELECT T1.ID FROM T1 JOIN T2 ON 1=1 RIGHT JOIN VT2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between view "PUBLIC"."VT2" and table "PUBLIC"."T2" and table "PUBLIC"."T1"|-ID'
pin '11 ON scope: ...after a RIGHT first join' 'SELECT T1.ID FROM T1 RIGHT JOIN T2 ON 1=1 JOIN VT2 ON ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2" and view "PUBLIC"."VT2"|-ID'
pin '11 ON scope: a column of an earlier comma item is -206' 'SELECT T1.ID FROM T1, T2 JOIN VT2 ON A = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"A"|-At line 1, column 38'
pin '11 ON scope: ...and so is its qualified name' 'SELECT T1.ID FROM T1, T2 JOIN VT2 ON T1.A = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"T1"."A"|-At line 1, column 38'
pin '11 ON scope: ...or a later one' 'SELECT T1.ID FROM T2 JOIN VT2 ON A = 1, T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"A"|-At line 1, column 34'
pin '11 keyword words: the value after KEY is read' 'SELECT UNICODE_CHAR(65), ENCRYPT(V USING RC4 KEY NOPE) FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 50'
pin '11 keyword words: ...before a later item' 'SELECT ENCRYPT(V USING RC4 KEY NOPE), UNICODE_CHAR(65) FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 32'
pin '11 keyword words: a HASH argument is read' 'SELECT UNICODE_CHAR(65), HASH(NOPE USING CRC32) FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 31'
pin '11 keyword words: a -206 after a cast'\''s CHARACTER SET' 'SELECT UNICODE_CHAR(65), CAST(V AS VARCHAR(10) CHARACTER SET UTF8) FROM T1 WHERE NOPE = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 82'
pin '11 keyword words: an UPDATE'\''s WHERE after a CRYPT_HASH value' 'UPDATE T3 SET NAME = CRYPT_HASH(NAME USING SHA256) WHERE NOPE = 1; ROLLBACK;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 58'
pin '11 LISTAGG is an aggregate: an ungrouped column beside it' 'SELECT UNICODE_CHAR(65), V, LISTAGG(V) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '11 LISTAGG is an aggregate: in a WHERE' 'SELECT UNICODE_CHAR(65) FROM T1 WHERE LISTAGG(V) = '\''x'\'';' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a WHERE clause, use HAVING (for aggregate only) instead'
pin '11 FILTER: an ungrouped column outside it is still invalid' 'SELECT UNICODE_CHAR(65), V, SUM(A) FILTER (WHERE B > 1) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '11 FILTER: a -206 inside it' 'SELECT UNICODE_CHAR(65), SUM(A) FILTER (WHERE NOPE > 1) FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 47'
pin '11 the implicit INSERT list without its COMPUTED column: two values are 21S01' 'INSERT INTO TC VALUES (UNICODE_CHAR(65), '\''b'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values'
pin '11 a bare * after another item is Token unknown *' 'SELECT UNICODE_CHAR(65), * FROM T1 ORDER BY 12;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 26|-*'
pin '11 ...before one, Token unknown at the comma' 'SELECT *, UNICODE_CHAR(65) FROM T1 ORDER BY 12;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 9|-,'
pin '11 ...with no ORDER BY' 'SELECT UNICODE_CHAR(65), * FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 26|-*'
pin '11 control: X.* beside an item counts its columns' 'SELECT UNICODE_CHAR(65), T1.* FROM T1 ORDER BY 12;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
ppin '11 phase: a DECFLOAT'\''s conversion error carries its invalid operation' 'INSERT INTO TT (DC) VALUES ('\''abc'\'')' 'PREPARED|EXECUTE ERR: |Decimal float invalid operation. An indeterminant error occurred during an operation. |conversion error from string "abc"'
ppin '11 phase: ...'\''1,5'\''' 'INSERT INTO TT (DC) VALUES ('\''1,5'\'')' 'PREPARED|EXECUTE ERR: |Decimal float invalid operation. An indeterminant error occurred during an operation. |conversion error from string "1,5"'
ppin '11 phase: ...an empty string' 'INSERT INTO TT (DD) VALUES ('\'''\'')' 'PREPARED|EXECUTE ERR: |Decimal float invalid operation. An indeterminant error occurred during an operation. |conversion error from string ""'
ppin '11 phase: a DECFLOAT(16) past its exponent is Decimal float overflow' 'INSERT INTO TT (DC) VALUES ('\''1e385'\'')' 'PREPARED|EXECUTE ERR: |Decimal float overflow. The exponent of a result is greater than the magnitude allowed.'
ppin '11 phase: ...'\''1e400'\''' 'INSERT INTO TT (DC) VALUES ('\''1e400'\'')' 'PREPARED|EXECUTE ERR: |Decimal float overflow. The exponent of a result is greater than the magnitude allowed.'
ppin '11 phase: a TIME of digits and colons is 22018' 'INSERT INTO TT (TM) VALUES ('\''25:00'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "25:00"'
ppin '11 phase: ...a TIME opening with a letter' 'INSERT INTO TT (TM) VALUES ('\''JAN-1-2020'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "JAN-1-2020"'
ppin '11 phase: a TIMESTAMP opening with a time is 22018' 'INSERT INTO TT (TSP) VALUES ('\''10:00 AM'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "10:00 AM"'
ppin '11 phase: ...with an offset after the time' 'INSERT INTO TT (TSP) VALUES ('\''10:00:00 +03:00'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "10:00:00 +03:00"'
ppin '11 phase: a plain TIMESTAMP that is no date' 'INSERT INTO TT (TSP) VALUES ('\''2020-13-01'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "2020-13-01"'
ppin '11 phase: a DATE with a zone suffix is 22018' 'INSERT INTO TT (DT) VALUES ('\''2020-01-01 10:00:00 +03:00'\'')' 'PREPARED|EXECUTE ERR: |conversion error from string "2020-01-01 10:00:00 +03:00"'
ppin '11 phase: '\''1e999'\'' into an INTEGER is 22003' 'INSERT INTO TT (I) VALUES ('\''1e999'\'')' 'PREPARED|EXECUTE ERR: |arithmetic exception, numeric overflow, or string truncation |numeric value is out of range'
# answered since the builtins merge; isql prints the blob ids, and this
# server's are its own temporary ones (cosmetic, the values agree)
differs '11 answered: a blob SUB_TYPE TEXT (the blob ids differ)' 'SELECT UNICODE_CHAR(65), CAST(V AS BLOB SUB_TYPE TEXT) FROM T1;' 'UNICODE_CHAR CAST|A 0:1|CAST:|apple|A 0:3|CAST:|banana|A 0:5|CAST:|cherry' 'UNICODE_CHAR CAST|A 0:40000001|CAST:|apple|A 0:40000002|CAST:|banana|A 0:40000003|CAST:|cherry'
pin '11 answered (the builtins merge): CRYPT_HASH .. USING SHA512' 'SELECT UNICODE_CHAR(65), CRYPT_HASH(V USING SHA512) FROM T1;' 'UNICODE_CHAR CRYPT_HASH|A 844D8779103B94C18F4AA4CC0C3B4474058580A991FBA85D3CA698A0BC9E52C5940FEB7A65A3A290E17E6B23EE943ECC4F73E7490327245B4FE5D5EFB590FEB2|A F8E3183D38E6C51889582CB260AB825252F395B4AC8FB0E6B13E9A71F7C10A80D5301E4A949F2783CB0C20205F1D850F87045F4420AD2271C8FD5F0CD8944BE3|A 22FDC354BD8871C8A5F3B1005071146C076A1530F8EBC239EC657FAC7446517B25DC9612DC16C568E79441A4C2B34AA741DBB3690146CFFB9635A6D9348A8BA8'
pin '11 answered (the builtins merge): HASH .. USING CRC32' 'SELECT UNICODE_CHAR(65), HASH(V USING CRC32) FROM T1;' 'UNICODE_CHAR HASH|A 1355820713|A -815297789|A 948551161'
pin '11 answered (the builtins merge): ...in a WHERE' 'SELECT UNICODE_CHAR(65) FROM T1 WHERE HASH(V USING CRC32) <> 0;' 'UNICODE_CHAR|A|A|A'
bare '11 REFUSED BARE: ENCRYPT .. USING CHACHA20 KEY .. IV' 'SELECT UNICODE_CHAR(65), ENCRYPT('\''abc'\'' USING CHACHA20 KEY '\''01234567890123456789012345678901'\'' IV '\''01234567'\'') FROM T1;' 'UNICODE_CHAR ENCRYPT|A 0E59F0|A 0E59F0|A 0E59F0'
bare '11 REFUSED BARE: DECRYPT .. USING AES MODE OFB' 'SELECT UNICODE_CHAR(65), DECRYPT(x'\''903EFD'\'' USING AES MODE OFB KEY '\''0123456701234567'\'' IV '\''0123456789012345'\'') FROM T1;' 'UNICODE_CHAR DECRYPT|A 616263|A 616263|A 616263'
bare '11 REFUSED BARE: ENCRYPT .. KEY <column>' 'SELECT UNICODE_CHAR(65), ENCRYPT(V USING RC4 KEY V) FROM T1;' 'UNICODE_CHAR ENCRYPT|A 790FA27019|A 36C7029312DE|A 0FC656A82C7F'
bare '11 REFUSED BARE: LISTAGG .. ON OVERFLOW ERROR' 'SELECT UNICODE_CHAR(65), LISTAGG(V, '\'','\'' ON OVERFLOW ERROR) WITHIN GROUP (ORDER BY V) FROM T1;' 'UNICODE_CHAR LIST|A 0:1|LIST:|apple,banana,cherry'
bare '11 REFUSED BARE: LISTAGG .. ON OVERFLOW TRUNCATE' 'SELECT UNICODE_CHAR(65), LISTAGG(V, '\'','\'' ON OVERFLOW TRUNCATE '\''...'\'' WITH COUNT) WITHIN GROUP (ORDER BY V) FROM T1;' 'UNICODE_CHAR LIST|A 0:1|LIST:|apple,banana,cherry'
bare '11 REFUSED BARE: RSA_SIGN_HASH .. KEY .. HASH SHA256' 'SELECT UNICODE_CHAR(65), RSA_SIGN_HASH(V KEY V HASH SHA256) FROM T1;' 'UNICODE_CHAR RSA_SIGN_HASH|Statement failed, SQLSTATE = 22023|TomCrypt library error: Invalid input packet.|-Importing RSA key'
bare '11 REFUSED BARE: COALESCE of a DATE and a text beside SUB_TYPE TEXT' 'SELECT COALESCE(D, '\''text'\''), CAST(V AS BLOB SUB_TYPE TEXT) FROM T1;' 'COALESCE CAST|2020-01-01 0:1|CAST:|apple|2021-06-15 0:3|CAST:|banana|text 0:5|CAST:|cherry'
pin '11 answered (the builtins merge): a DELETE over CRYPT_HASH' 'DELETE FROM T3 WHERE CRYPT_HASH(NAME USING SHA256) = '\''x'\''; ROLLBACK;' ''
bare '11 REFUSED BARE: an INSERT of ENCRYPT' 'INSERT INTO T3 (K, NAME) VALUES (1, ENCRYPT('\''abc'\'' USING RC4 KEY '\''0123456701234567'\'')); ROLLBACK;' ''
bare '11 REFUSED BARE (Token unknown USING): SUBSTRING .. USING CHARACTERS' 'SELECT UNICODE_CHAR(65), SUBSTRING(V FROM 1 USING CHARACTERS) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 45|-USING'
pin '11 answered (the builtins merge): SUM .. FILTER' 'SELECT UNICODE_CHAR(65), SUM(A) FILTER (WHERE B > 1) FROM T1;' 'UNICODE_CHAR SUM|A 10'
pin '11 answered (the builtins merge): COUNT(*) FILTER beside MAX' 'SELECT UNICODE_CHAR(65), COUNT(*) FILTER (WHERE A > 1), MAX(V) FROM T1;' 'UNICODE_CHAR COUNT MAX|A 2 cherry'
pin '11 answered (the builtins merge): FILTER over a GROUP BY' 'SELECT A, UNICODE_CHAR(65), COUNT(*) FILTER (WHERE B > 1) FROM T1 GROUP BY A;' 'A UNICODE_CHAR COUNT|<null> A 1|10 A 1|20 A 0'
pin '11 answered (the builtins merge): PERCENTILE_CONT WITHIN GROUP' 'SELECT UNICODE_CHAR(65), PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY A) FROM T1;' 'UNICODE_CHAR PERCENTILE_CONT|A 15.00000000000000'
pin '11 answered (the builtins merge): PERCENTILE_DISC WITHIN GROUP DESC' 'SELECT UNICODE_CHAR(65), PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY A DESC) FROM T1;' 'UNICODE_CHAR PERCENTILE_DISC|A 20'
pin '11 answered (the builtins merge): a HAVING'\''s FILTER' 'SELECT UNICODE_CHAR(65), COUNT(*) FROM T1 GROUP BY A HAVING COUNT(*) FILTER (WHERE B > 0) >= 0;' 'UNICODE_CHAR COUNT|A 1|A 1|A 1'
pin '11 answered (the builtins merge): one value for a table with a COMPUTED column' 'INSERT INTO TC VALUES (UNICODE_CHAR(65)); ROLLBACK;' ''
bare '11 REFUSED BARE: a TIMESTAMP with an offset' 'INSERT INTO TT (TSP) VALUES ('\''2020-01-01 10:00:00 +03:00'\''); ROLLBACK;' ''
bare '11 REFUSED BARE: a TIMESTAMP with a region' 'INSERT INTO TT (TSP) VALUES ('\''2020-01-01 10:00 Europe/Paris'\''); ROLLBACK;' ''
bare '11 REFUSED BARE: a TIMESTAMP with a negative offset' 'INSERT INTO TT (TSP) VALUES ('\''2020-01-01 -03:00'\''); ROLLBACK;' ''
bare '11 REFUSED BARE: '\''0e999'\'' into an INTEGER stores 0' 'INSERT INTO TT (I) VALUES ('\''0e999'\''); ROLLBACK;' ''
bare '11 REFUSED BARE: '\''snan'\'' into a DECFLOAT stores sNaN' 'INSERT INTO TT (DC) VALUES ('\''snan'\''); ROLLBACK;' ''
bare '11 REFUSED BARE (22009 region AM): a TIME with AM' 'INSERT INTO TT (TM) VALUES ('\''10:00 AM'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22009|Invalid time zone region: AM'
bare '11 REFUSED BARE (22009 region .00): a TIME with dots' 'INSERT INTO TT (TM) VALUES ('\''10.00.00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22009|Invalid time zone region: .00'
bare '11 REFUSED BARE (22009 offset): a date into a TIME' 'INSERT INTO TT (TM) VALUES ('\''2020-13-01'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22009|Invalid time zone offset: -13-01 - must use format +/-hours:minutes and be between -14:00 and +14:00'
bare '11 REFUSED BARE (22009 region T10:00:00): an ISO T' 'INSERT INTO TT (TSP) VALUES ('\''2020-01-01T10:00:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22009|Invalid time zone region: T10:00:00'
bare '11 REFUSED BARE (22009 region ,10:00): a comma' 'INSERT INTO TT (TSP) VALUES ('\''2020-01-01,10:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22009|Invalid time zone region: ,10:00'
bare '11 REFUSED BARE (22009 offset +3): a short offset' 'INSERT INTO TT (TSP) VALUES ('\''2020-01-01 10:00 +3'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22009|Invalid time zone offset: +3 - must use format +/-hours:minutes and be between -14:00 and +14:00'

echo '--- 12. THE REVIEW OF THE MERGED BINARY: MULTI-BYTE TEXT NEVER DROPS THE ATTACHMENT, THE SELECT LIST FIRST, THE LAWS IN THEIR PHASE'
CS=UTF8 bare '12 REFUSED BARE: a call then a multi-byte character within a word'\''s length (the panic: 08006)' 'SELECT 1 FROM RDB$DATABASE WHERE ABS(1) = '\''éé'\''; SELECT 1 FROM RDB$DATABASE;' 'CONSTANT|Statement failed, SQLSTATE = 22018|conversion error from string "#xc3#xa9#xc3#xa9"|CONSTANT|1' 'CONSTANT|1'
bare '12 REFUSED BARE: ...under NONE' 'SELECT 1 FROM RDB$DATABASE WHERE ABS(1) = '\''éé'\''; SELECT 1 FROM RDB$DATABASE;' 'CONSTANT|Statement failed, SQLSTATE = 22018|conversion error from string "#xc3#xa9#xc3#xa9"|CONSTANT|1' 'CONSTANT|1'
CS=UTF8 bare '12 REFUSED BARE: ...after OVERLAY' 'SELECT ID FROM CU WHERE OVERLAY(W PLACING '\''é'\'' FROM 1) = '\''éé'\''; SELECT 1 FROM RDB$DATABASE;' 'CONSTANT|1' 'CONSTANT|1'
CS=UTF8 bare '12 REFUSED BARE: ...after a CAST to a collated domain' 'SELECT CAST('\''a'\'' AS DCOLL) = '\''é'\'' FROM RDB$DATABASE; SELECT 1 FROM RDB$DATABASE;' 'BOOL|<false>|CONSTANT|1' 'CONSTANT|1'
CS=UTF8 bare '12 REFUSED BARE: ...after FIRST_DAY' 'SELECT ID FROM CU WHERE FIRST_DAY(OF MONTH FROM CAST(NULL AS DATE)) = '\''éé'\''; SELECT 1 FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = 22018|conversion error from string "#xc3#xa9#xc3#xa9"|CONSTANT|1' 'CONSTANT|1'
CS=UTF8 bare '12 REFUSED BARE: ...after an unquoted multi-byte name in a parenthesis' 'SELECT (é€€) FROM T1; SELECT 1 FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 9|-�|CONSTANT|1' 'CONSTANT|1'
CS=UTF8 bare '12 REFUSED BARE: ...a multi-byte byte glued to a call' 'SELECT ABS(1)é, NOPE FROM T1; SELECT 1 FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 14|-�|CONSTANT|1' 'CONSTANT|1'
CS=UTF8 bare '12 REFUSED BARE: ...a multi-byte byte in a name' 'SELECT IDé FROM T1; SELECT 1 FROM RDB$DATABASE;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 10|-�|CONSTANT|1' 'CONSTANT|1'
CS=UTF8 pin '12 non-ASCII: the -206 column counts bytes' 'SELECT '\''éé'\'', NOSUCH FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 16'
CS=UTF8 pin '12 non-ASCII: ...on a later line' 'SELECT '\''éé'\'',
 '\''é'\'', NOSUCH FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 3, column 8'
CS=UTF8 pin '12 non-ASCII: a quoted multi-byte name' 'SELECT "é" FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"é"|-At line 1, column 8'
CS=UTF8 pin '12 non-ASCII: -206 beside a literal' 'SELECT NOSUCH, '\''é'\'' FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 8'
CS=UTF8 pin '12 non-ASCII: the tables'\'' 42702' 'SELECT '\''é'\'', ID FROM T1, T2;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
CS=UTF8 pin '12 non-ASCII: the select list'\''s 42702' 'SELECT ID, ID, '\''é'\'' FROM T1 ORDER BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and a field in the select list with name|-ID'
CS=UTF8 pin '12 non-ASCII: a position' 'SELECT '\''é'\'' FROM T1 ORDER BY 2;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid column position used in the ORDER BY clause'
CS=UTF8 pin '12 non-ASCII: an aggregate in the WHERE' 'SELECT ID FROM T1 WHERE COUNT(*) > 0 AND V = '\''é'\'';' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a WHERE clause, use HAVING (for aggregate only) instead'
CS=UTF8 pin '12 non-ASCII: an aggregate in the GROUP BY' 'SELECT '\''é'\'' FROM T1 GROUP BY COUNT(*);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Cannot use an aggregate or window function in a GROUP BY clause'
CS=UTF8 pin '12 non-ASCII: a nested aggregate' 'SELECT SUM(SUM(A)), '\''é'\'' FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Nested aggregate and window functions are not allowed'
CS=UTF8 pin '12 non-ASCII: SUM of a text' 'SELECT SUM(V) FROM T1 WHERE V <> '\''é'\'';' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
CS=UTF8 pin '12 non-ASCII: HY004 COALESCE' 'SELECT COALESCE(D, 1), '\''é'\'' FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
CS=UTF8 pin '12 non-ASCII: HY004 CASE' 'SELECT CASE WHEN ID = 1 THEN D ELSE 1 END, '\''é'\'' FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
CS=UTF8 pin '12 non-ASCII: COUNT(DISTINCT *)' 'SELECT '\''é'\'', COUNT(DISTINCT *) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 29|-*'
CS=UTF8 pin '12 non-ASCII: a bare star' 'SELECT '\''é'\'', * FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 14|-*'
CS=UTF8 pin '12 non-ASCII: an INSERT'\''s -206' 'INSERT INTO T3 (K, NAME, NOPE) VALUES (1, '\''é'\'', 2);' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 26'
CS=UTF8 pin '12 non-ASCII: an INSERT'\''s count' 'INSERT INTO T3 (K) VALUES (1, '\''é'\'');' 'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values'
CS=UTF8 pin '12 non-ASCII: an UPDATE'\''s -206' 'UPDATE T3 SET NAME = '\''é'\'' WHERE NOPE = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 33'
CS=UTF8 pin '12 non-ASCII: a DELETE'\''s -206' 'DELETE FROM T3 WHERE NAME = '\''é'\'' AND NOPE = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 38'
CS=UTF8 pin '12 non-ASCII: a literal into a DATE' 'INSERT INTO TS (D) VALUES ('\''é'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "#xc3#xa9"'
CS=UTF8 pin '12 non-ASCII: a literal into a SMALLINT' 'INSERT INTO TS (S) VALUES ('\''é'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "#xc3#xa9"'
CS=UTF8 pin '12 non-ASCII: a truncation counts a NONE column'\''s bytes' 'INSERT INTO TS (V) VALUES ('\''éééé'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 3, actual 8'
CS=UTF8 pin '12 non-ASCII: a NONE key value prints its bytes' 'INSERT INTO KZ VALUES ('\''é'\''); INSERT INTO KZ VALUES ('\''é'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_11" on table "PUBLIC"."KZ"|-Problematic key value is ("V" = '\''é'\'')'
CS=UTF8 pin '12 non-ASCII: after a FILTER' 'SELECT COUNT(*) FILTER (WHERE V = '\''é'\''), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 42'
CS=UTF8 pin '12 non-ASCII: after WITHIN GROUP' 'SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY A) || '\''é'\'', NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 64'
CS=UTF8 pin '12 non-ASCII: after OVER' 'SELECT SUM(A) OVER ()||'\''é'\'', NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 30'
CS=UTF8 pin '12 non-ASCII: after a call' 'SELECT ABS(1)||'\''é'\'', NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 22'
CS=UTF8 pin '12 non-ASCII: after GEN_ID' 'SELECT GEN_ID(SM, 0) || '\''é'\'', NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 31'
CS=UTF8 pin '12 non-ASCII: in a CASE' 'SELECT CASE WHEN ID = 1 THEN '\''é'\'' ELSE D END, NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 47'
CS=UTF8 pin '12 non-ASCII: in an IIF' 'SELECT IIF(ID = 1, '\''é'\'', D), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 30'
CS=UTF8 pin '12 non-ASCII: in an ORDER BY' 'SELECT ID FROM T1 ORDER BY '\''é'\'', NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 34'
CS=UTF8 pin '12 non-ASCII: in a GROUP BY and HAVING' 'SELECT ID FROM T1 GROUP BY ID, '\''é'\'' HAVING NOPE > '\''é'\'';' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 44'
CS=UTF8 pin '12 non-ASCII: in a window' 'SELECT ROW_NUMBER() OVER (ORDER BY '\''é'\''), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 43'
CS=UTF8 pin '12 non-ASCII: in an ON' 'SELECT T1.ID FROM T1 JOIN T2 ON T2.S = '\''é'\'' AND ID = 1;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
CS=UTF8 pin '12 non-ASCII: in a subquery' 'SELECT (SELECT '\''é'\'' FROM T2 WHERE NOPE = '\''é'\'') FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 35'
CS=UTF8 pin '12 non-ASCII: in a CAST' 'SELECT CAST('\''é'\'' AS VARCHAR(5)), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 34'
CS=UTF8 pin '12 non-ASCII: in a SUBSTRING' 'SELECT SUBSTRING('\''éé'\'' FROM 1 FOR 1), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 40'
CS=UTF8 pin '12 non-ASCII: in a TRIM' 'SELECT TRIM(BOTH '\''é'\'' FROM V), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 32'
CS=UTF8 pin '12 non-ASCII: in HASH .. USING' 'SELECT HASH('\''é'\'' USING CRC32), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 32'
CS=UTF8 pin '12 non-ASCII: in LISTAGG' 'SELECT LISTAGG(V, '\''é'\'') WITHIN GROUP (ORDER BY V), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 52'
CS=UTF8 bare '12 REFUSED BARE: non-ASCII: a glued alias after a literal' 'SELECT '\''é'\''X FROM T1;' 'X|é|é|é'
CS=UTF8 bare '12 REFUSED BARE: non-ASCII: a glued quoted alias' 'SELECT COUNT(*)"é" FROM T1;' 'é|3'
bare '12 REFUSED BARE: GROUP BY a bare name: the select list first (a qualified item answers)' 'SELECT T1.ID, COUNT(*) FROM T1, T2 GROUP BY ID;' 'ID COUNT|1 3|2 3|3 3'
bare '12 REFUSED BARE: ...over a JOIN' 'SELECT T1.ID FROM T1 JOIN T2 ON T1.ID = T2.ID GROUP BY ID;' 'ID|1|2|3'
bare '12 REFUSED BARE: ...an aliased FROM' 'SELECT A.ID FROM T1 A, T2 B GROUP BY ID;' 'ID|1|2|3'
bare '12 REFUSED BARE: ...a parenthesised field' 'SELECT (T1.ID) FROM T1, T2 GROUP BY ID;' 'ID|1|2|3'
bare '12 REFUSED BARE: ...with a HAVING' 'SELECT T1.ID FROM T1, T2 GROUP BY ID HAVING COUNT(*) > 0;' 'ID|1|2|3'
pin '12 GROUP BY: two fields of the name' 'SELECT T1.ID, T2.ID FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and a field in the select list with name|-ID'
pin '12 GROUP BY: the same field twice' 'SELECT ID, ID FROM T1 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and a field in the select list with name|-ID'
pin '12 GROUP BY: two stars' 'SELECT T1.*, T2.* FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and a field in the select list with name|-ID'
pin '12 GROUP BY: two aliases' 'SELECT T1.A X, T2.X X FROM T1, T2 GROUP BY X;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between an alias and an alias in the select list with name|-X'
pin '12 GROUP BY: an alias, then a field' 'SELECT T2.X ID, T1.ID FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between an alias and a field in the select list with name|-ID'
pin '12 GROUP BY: a field, then an alias' 'SELECT T1.ID, T2.X ID FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and an alias in the select list with name|-ID'
pin '12 GROUP BY: an aggregate'\''s alias, then a field' 'SELECT COUNT(*) ID, T1.ID FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between an alias and a field in the select list with name|-ID'
pin '12 GROUP BY: one field matches, the other item is ungrouped' 'SELECT T1.A, T2.ID FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '12 GROUP BY: an expression is no field' 'SELECT T1.ID + 0 FROM T1, T2 GROUP BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
pin '12 GROUP BY: an alias inside an expression is -206' 'SELECT A X FROM T1 GROUP BY X + 0;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"X"|-At line 1, column 29'
pin '12 ORDER BY: an alias inside an expression is -206' 'SELECT A X FROM T1 ORDER BY X + 0;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"X"|-At line 1, column 29'
pin '12 ORDER BY: two fields of the name (answered before)' 'SELECT ID, ID FROM T1 ORDER BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and a field in the select list with name|-ID'
pin '12 ORDER BY: two stars (answered before)' 'SELECT * FROM T1, T2 ORDER BY ID;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between a field and a field in the select list with name|-ID'
pin '12 ORDER BY: two aliases' 'SELECT T1.A X, T2.X X FROM T1, T2 ORDER BY X;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between an alias and an alias in the select list with name|-X'
pin '12 ORDER BY: one qualified field answers' 'SELECT T1.ID FROM T1, T2 ORDER BY ID;' 'ID|1|1|1|2|2|2|3|3|3'
pin '12 HAVING: no select-list lookup' 'SELECT T1.ID FROM T1, T2 GROUP BY T1.ID HAVING ID > 0;' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
bare '12 REFUSED BARE: a glued alias after a call' 'SELECT COUNT(*)X FROM T1;' 'X|3'
bare '12 REFUSED BARE: a glued alias after a literal' 'SELECT '\''a'\''X FROM T1;' 'X|a|a|a'
bare '12 REFUSED BARE: a glued alias after a quoted name' 'SELECT "ID"X FROM T1;' 'X|1|2|3'
bare '12 REFUSED BARE: a glued quoted alias after a name' 'SELECT ID"X" FROM T1;' 'X|1|2|3'
bare '12 REFUSED BARE: a glued alias over a GROUP BY' 'SELECT SUM(A)X FROM T1 GROUP BY ID;' 'X|10|20|<null>'
bare '12 REFUSED BARE: a glued alias after a parenthesis' 'SELECT (A)X FROM T1;' 'X|10|20|<null>'
pin '12 SUM of a text before a HAVING'\''s -206' 'SELECT SUM(V) FROM T1 HAVING NOPE = 1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 AVG of a date before a HAVING'\''s -206' 'SELECT AVG(D) FROM T1 GROUP BY ID HAVING NOPE > 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for AVG in dialect 3 must be numeric'
pin '12 SUM of a text before the select list'\''s judgement' 'SELECT ID, SUM(V) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ...before the HAVING'\''s judgement' 'SELECT SUM(V) FROM T1 HAVING A > 1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ...before a nested aggregate' 'SELECT SUM(SUM(V)) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ...and after a nested one'\''s own SUM' 'SELECT SUM(SUM(A)), SUM(V) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ORDER BY'\''s SUM before its judgement' 'SELECT COUNT(*) FROM T1 ORDER BY ID, SUM(V);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ...after the select list'\''s judgement' 'SELECT ID FROM T1 ORDER BY SUM(V);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '12 ...after the ORDER BY'\''s -206' 'SELECT COUNT(*) FROM T1 ORDER BY SUM(V), NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 42'
pin '12 a HAVING'\''s SUM after the HAVING'\''s -206' 'SELECT COUNT(*) FROM T1 HAVING SUM(V) > 0 AND NOPE = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 47'
pin '12 a HAVING'\''s SUM' 'SELECT COUNT(*) FROM T1 HAVING SUM(V) > 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 a HAVING'\''s SUM before its judgement' 'SELECT ID FROM T1 GROUP BY ID HAVING SUM(V) > 0 AND A > 1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 the ORDER BY'\''s judgement before the HAVING'\''s SUM' 'SELECT COUNT(*) FROM T1 HAVING SUM(V) > 0 ORDER BY ID;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the ORDER BY clause (not contained in either an aggregate function or the GROUP BY clause)'
pin '12 a window'\''s SUM after the ORDER BY'\''s -206' 'SELECT SUM(V) OVER () FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 40'
pin '12 a window'\''s SUM' 'SELECT SUM(V) OVER () FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 HY004 before an ORDER BY -206' 'SELECT COALESCE(D, 1) FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 in the ORDER BY, before its next item' 'SELECT ID FROM T1 ORDER BY COALESCE(D, 1), NOPE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 before the grouping law' 'SELECT ID, COALESCE(D, 1) FROM T1 GROUP BY ID;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 before SUM' 'SELECT SUM(V), COALESCE(D, 1) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 in a HAVING' 'SELECT ID FROM T1 GROUP BY ID HAVING COALESCE(D, 1) = 1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 in a GROUP BY' 'SELECT ID FROM T1 GROUP BY COALESCE(D, 1);' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 in a WHERE, right operand first' 'SELECT ID FROM T1 WHERE NOPE = 1 AND COALESCE(D, 1) = 1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 ...the -206 of the right operand first' 'SELECT ID FROM T1 WHERE COALESCE(D, 1) = 1 AND NOPE = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 48'
pin '12 HY004 inside SUM' 'SELECT SUM(COALESCE(D, 1)) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 after a later position' 'SELECT COALESCE(D, 1) FROM T1 ORDER BY 5;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 over a SUM' 'SELECT COALESCE(SUM(A), D) FROM T1 GROUP BY D;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 over a COUNT' 'SELECT COALESCE(COUNT(*), D) FROM T1 GROUP BY D;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 HY004 over a MAX' 'SELECT COALESCE(MAX(D), 1) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression COALESCE'
pin '12 an IIF is typed late: after the ORDER BY'\''s -206' 'SELECT IIF(ID = 1, D, 1) FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 43'
pin '12 ...a searched CASE too' 'SELECT CASE WHEN ID = 1 THEN D ELSE 1 END FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 60'
pin '12 ...after the grouping law' 'SELECT IIF(ID = 1, D, 1) FROM T1 GROUP BY ID;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '12 ...after a SUM'\''s own error' 'SELECT IIF(ID = 1, D, 1), SUM(V) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ...after a -206 left of it' 'SELECT ID FROM T1 WHERE NOPE = 1 AND IIF(ID = 1, D, 1) = 1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 25'
pin '12 ...alone the HY004 CASE' 'SELECT ID FROM T1 WHERE IIF(ID = 1, D, 1) = 1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...inside an aggregate: typed as the aggregate'\''s clause is remapped' 'SELECT SUM(IIF(ID = 1, D, 1)) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...inside MAX' 'SELECT MAX(IIF(ID = 1, D, 1)) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...inside COUNT' 'SELECT COUNT(IIF(ID = 1, D, 1)) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...a searched CASE inside SUM' 'SELECT SUM(CASE WHEN ID = 1 THEN D ELSE 1 END) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...inside MAX over a GROUP BY' 'SELECT V, MAX(CASE WHEN ID = 1 THEN D ELSE 1 END) FROM T1 GROUP BY V;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...in an aggregate'\''s FILTER' 'SELECT COUNT(*) FILTER (WHERE IIF(ID = 1, D, 1) = 1) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...a FILTER'\''s is typed late, after the grouping law' 'SELECT ID, COUNT(*) FILTER (WHERE IIF(ID = 1, D, 1) = 1) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)'
pin '12 ...inside an aggregate, after a GROUP BY -206' 'SELECT SUM(IIF(ID = 1, D, 1)) FROM T1 GROUP BY NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 48'
pin '12 ...after an ORDER BY -206' 'SELECT SUM(IIF(ID = 1, D, 1)) FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 48'
pin '12 ...before the select list'\''s judgement' 'SELECT ID, SUM(IIF(ID = 1, D, 1)) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...before a HAVING'\''s -206' 'SELECT SUM(IIF(ID = 1, D, 1)) FROM T1 HAVING NOPE = 1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...before a later SUM'\''s own error' 'SELECT SUM(IIF(ID = 1, D, 1)), SUM(V) FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...after an earlier SUM'\''s own error' 'SELECT SUM(V), SUM(IIF(ID = 1, D, 1)) FROM T1;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-expression evaluation not supported|-Argument for SUM in dialect 3 must be numeric'
pin '12 ...before a HAVING'\''s SUM' 'SELECT SUM(IIF(ID = 1, D, 1)) FROM T1 GROUP BY ID HAVING SUM(V) > 0;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...in an ORDER BY aggregate' 'SELECT ID FROM T1 GROUP BY ID ORDER BY MAX(IIF(ID = 1, D, 1));' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 ...under a window' 'SELECT SUM(IIF(ID = 1, D, 1)) OVER () FROM T1;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-01-01 25:00:00' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 25:00:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 25:00:00"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-01-01 10:60:00' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 10:60:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 10:60:00"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-01-01 10:00:61' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 10:00:61'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 10:00:61"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-01-01 24:00' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 24:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 24:00"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-01-01 10:00:00.12345' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 10:00:00.12345'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 10:00:00.12345"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-01-01 10' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 10'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 10"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 0000-02-30 25:00' 'INSERT INTO LD (TS) VALUES ('\''0000-02-30 25:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-02-30 25:00"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 1-JAN-0000 99:00' 'INSERT INTO LD (TS) VALUES ('\''1-JAN-0000 99:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "1-JAN-0000 99:00"'
pin '12 a year 0 TIMESTAMP: its time is judged first: 1-JAN-2020 99:00' 'INSERT INTO LD (TS) VALUES ('\''1-JAN-2020 99:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "1-JAN-2020 99:00"'
pin '12 ...not the first column' 'INSERT INTO LD (TS, D) VALUES ('\''0000-01-01 25:00'\'', '\''0000-01-01'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 25:00"'
pin '12 ...a time the grammar reads is the range' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 10:00:00:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22008|value exceeds the range for valid timestamps'
pin '12 ...a month name' 'INSERT INTO LD (TS) VALUES ('\''1-JAN-0000 10:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22008|value exceeds the range for valid timestamps'
pin '12 a simple CASE is passed like a DECODE' 'SELECT CASE ID WHEN 1 THEN D ELSE 1 END FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression CASE'
pin '12 MAXVALUE at its pass' 'SELECT MAXVALUE(D, 1) FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression MAXVALUE'
pin '12 HY004 of a DECODE' 'SELECT DECODE(ID, 1, D, 1) FROM T1 ORDER BY NOPE;' 'Statement failed, SQLSTATE = HY004|SQL error code = -104|-Datatypes are not comparable in expression DECODE'
pin '12 the -206 of a plain field before HY004' 'SELECT COALESCE(D, 1), NOPE FROM T1;' 'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOPE"|-At line 1, column 24'
pin '12 two FROM items under one alias' 'SELECT ID FROM T1 WHERE ID = ANY (SELECT ID FROM T1 X, T2 X);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-alias "X" conflicts with an alias in the same statement'
pin '12 ...before the level'\''s -206' 'SELECT ID FROM T1 WHERE ID = ANY (SELECT NOPE FROM T1 X, T2 X);' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-alias "X" conflicts with an alias in the same statement'
pin '12 an unaliased name beside the alias is no conflict' 'SELECT ID FROM T1 WHERE ID = ANY (SELECT ID FROM T1, T2 T1);' 'Statement failed, SQLSTATE = 42702|Dynamic SQL Error|-SQL error code = -204|-Ambiguous field name between table "PUBLIC"."T1" and table "PUBLIC"."T2"|-ID'
bare '12 REFUSED BARE: the clauses out of order: the parser'\''s Token unknown' 'SELECT COUNT(*) FROM T1 ORDER BY SUM(V) HAVING NOPE > 0;' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 41|-HAVING'
pin '12 a year 0 DATE is 22008' 'INSERT INTO LD (D) VALUES ('\''0000-01-01'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22008|value exceeds the range for valid dates'
pin '12 ...an impossible day of year 0 too' 'INSERT INTO LD (D) VALUES ('\''0000-02-30'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22008|value exceeds the range for valid dates'
pin '12 ...a month name' 'INSERT INTO LD (D) VALUES ('\''1-JAN-0000'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22008|value exceeds the range for valid dates'
pin '12 ...a month 13 is the conversion' 'INSERT INTO LD (D) VALUES ('\''0000-13-01'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-13-01"'
pin '12 ...a five-digit year the conversion' 'INSERT INTO LD (D) VALUES ('\''10000-01-01'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "10000-01-01"'
pin '12 a year 0 TIMESTAMP is 22008 timestamps' 'INSERT INTO LD (TS) VALUES ('\''0000-01-01 10:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22008|value exceeds the range for valid timestamps'
pin '12 a year 0 DATE with a time is the conversion' 'INSERT INTO LD (D) VALUES ('\''0000-01-01 10:00'\''); ROLLBACK;' 'Statement failed, SQLSTATE = 22018|conversion error from string "0000-01-01 10:00"'

pin '12 a long key value is cut to 250 bytes and marked, the next segment whole' 'INSERT INTO KL VALUES ('\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\'', 1); INSERT INTO KL VALUES ('\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\'', 1); ROLLBACK;' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_12" on table "PUBLIC"."KL"|-Problematic key value is ("V" = '\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..., "B" = 1)'
CS=UTF8 pin '12 non-ASCII: ...at a character'\''s edge' 'INSERT INTO KL VALUES ('\''éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé'\'', 1); INSERT INTO KL VALUES ('\''éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé'\'', 1); ROLLBACK;' 'Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_12" on table "PUBLIC"."KL"|-Problematic key value is ("V" = '\''éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé..., "B" = 1)'
if grep -aq 'panicked at' "/tmp/fc-serve-errvec-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
else echo "OK   no panic"; fi
echo "ran $ran checks"
if [ "$ran" -lt 428 ]; then echo "FAIL only $ran checks ran (floor 428)"; fail=1; fi
exit $fail
