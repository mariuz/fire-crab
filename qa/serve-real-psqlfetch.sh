#!/bin/bash
# PSQL, SECOND ROUND: the rows a FOR SELECT fetched before its source
# raised, a text argument's width, a trigger's typed locals, a
# function's frame on the BLR path, EXECUTE PROCEDURE's first SUSPEND,
# and a bare local inside a value the planner answers.
#
# Measured on engine 2182 and matched:
#
#   * A FOR SELECT fetches its source ONE ROW AT A TIME, so the body has
#     run for every row before the fetch that raises. This server read
#     the source whole first and raised before the body ran at all:
#     `FOR SELECT R FROM PSEL(0)` (row 1, then E_SIMPLE) appending into
#     a string under `WHEN EXCEPTION E_SIMPLE` answered ' caught' for
#     '1 caught' - a wrong value, made reachable when the previous round
#     taught the handler to see a callee's exception - a WHEN ANY
#     counter over a source failing at its fourth row answered 100 for
#     103, and a selectable block suspending each fetched row delivered
#     the 22012 without the rows 1 and 2. A LEAVE before the failing row
#     closes the cursor without ever meeting the raise;
#   * a TEXT argument into a SMALLINT/INTEGER parameter obeys the width
#     like an integer one: `Q5('70000')` is the locationless 22003 where
#     this answered 70000, and `PS('70000')` carried a spurious `At
#     procedure` item;
#   * a TRIGGER's locals convert into their declared types as a
#     procedure's do: a NUMERIC(10,2) local taking 1.005 stored 1.0050
#     for 1.0100, a CHAR(4) local 'ab|' for 'ab  |', and 70000 into a
#     SMALLINT local INSERTED the row where the engine raises 22003 `At
#     trigger` and the INSERT fails;
#   * a stored FUNCTION the BLR executor runs names its frame on an
#     output overflow: `F3(33)` is 22003 `-At function "PUBLIC"."F3"`,
#     where the BLR path answered the 22003 bare;
#   * EXECUTE PROCEDURE takes the FIRST SUSPEND's row and the body runs
#     no further: `EXECUTE PROCEDURE PE3` (1, 2, then 1/0) is X = 1 where
#     this raised 22012 - the 2182 compiler emits a SUSPEND as a bare
#     `blr_send` with no `blr_stall` after it, and the executor halted
#     only at a stall;
#   * a bare local in a value only the planner answers is that local:
#     `R = X + 0.01`, `X = -X`, `CHAR_LENGTH(X)` all refused (the bare X
#     was read as a column of RDB$DATABASE). A CAST(<integer> AS <int
#     type>) call argument is its value (`PI(CAST(5 AS BIGINT))` = 10,
#     refused).
#
# RECORDED, not fixed: an EXECUTE BLOCK the procedure compiler (the
# fire-crab-dsql crate) refuses at PREPARE still refuses - a call to a
# stored function in the body, an INT128 or NUMERIC(19..38) output or
# local, a scaled literal past 32 bits, IIF, `EXTRACT(DAY FROM D)` over a
# local (the engine answers 26 - this used to be a WRONG error, -204 Table
# unknown "D", the FROM of EXTRACT read as a clause; it is a plain refusal
# since qa/serve-real-psqlassign.sh section 8). A WHERE over a procedure that raises after suspending
# raises without the row the engine delivers first (the rows are read
# as a set there), and a UNION ALL over it refuses. `EXECUTE PROCEDURE PY0 ()` answers where
# the engine raises -104 on the empty list. All pinned below.
#
# Usage: qa/serve-real-psqlfetch.sh [port]   (default 5402)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5402}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/psqlfetch-eng.fdb"; FC="$D/psqlfetch-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE EXCEPTION E_SIMPLE 'simple';
CREATE TABLE T (ID INTEGER);
INSERT INTO T VALUES (1); INSERT INTO T VALUES (2); INSERT INTO T VALUES (0); INSERT INTO T VALUES (4);
CREATE TABLE LG (N INTEGER);
CREATE TABLE TT (ID INTEGER, V NUMERIC(10,4), W NUMERIC(10,4), S VARCHAR(20));
SET TERM ^;
CREATE PROCEDURE PSEL (A INTEGER) RETURNS (R INTEGER) AS BEGIN R = 1; SUSPEND; IF (A = 0) THEN EXCEPTION E_SIMPLE; R = 2; SUSPEND; END^
CREATE PROCEDURE PE4 RETURNS (X INTEGER) AS DECLARE I INTEGER; BEGIN FOR SELECT ID FROM T ORDER BY ID DESC INTO :I DO BEGIN X = 10 / I; SUSPEND; END END^
CREATE PROCEDURE PE3 RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; X = 2; SUSPEND; X = 1/0; SUSPEND; END^
CREATE PROCEDURE PE5 (A INTEGER) RETURNS (X SMALLINT) AS BEGIN X = A; SUSPEND; X = A * 1000; SUSPEND; END^
CREATE PROCEDURE PL RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; INSERT INTO LG VALUES (1); X = 2; SUSPEND; END^
CREATE PROCEDURE Q5 (A SMALLINT) RETURNS (R INTEGER) AS BEGIN R = A; SUSPEND; END^
CREATE PROCEDURE PS (A SMALLINT) RETURNS (R SMALLINT) AS BEGIN R = A + 1; SUSPEND; END^
CREATE PROCEDURE PI (A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A * 2; SUSPEND; END^
CREATE PROCEDURE PY0 RETURNS (R INTEGER) AS BEGIN R = 7; SUSPEND; END^
CREATE FUNCTION F3 (A INTEGER) RETURNS SMALLINT AS BEGIN RETURN A * 1000; END^
CREATE TRIGGER TBI FOR TT BEFORE INSERT AS DECLARE X NUMERIC(10,2); DECLARE C CHAR(4); DECLARE K SMALLINT; BEGIN X = NEW.V; NEW.W = X; C = 'ab'; NEW.S = C || '|'; IF (NEW.ID = 9) THEN K = 70000; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/psqlfetch-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/psqlfetch-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/psqlfetch-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-psqlfetch-$PORT.log" 2>&1 & srv=$!
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
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
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
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# RECORDED: the engine answers, this server REFUSES (a clean error, never
# a wrong value). Fails the day the two agree, so the cell gets promoted.
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS; promote the cell"; fail=1
    elif [ "${fv#*Statement failed}" = "$fv" ]; then
        echo "FAIL $1 - this server neither answers nor refuses"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: the engine answers [$ev], this server refuses)"; fi
}
# RECORDED: a KNOWN DIFFERENCE, both sides pinned - this server's answer
# is not the engine's and is written down as it is. Fails the day either
# side changes, so the cell gets promoted or re-examined.
differs() { # <label> <script> <engine-output> <this-server-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THE TWO NOW AGREE; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server answers [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: the engine [$ev], this server [$fv])"; fi
}
# one EXECUTE BLOCK (or any ^-terminated PSQL statement) as a script
eb() { printf 'SET TERM ^;\n%s^\nSET TERM ;^\n' "$1"; }
AR='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
DIV='Statement failed, SQLSTATE = 22012|arithmetic exception, numeric overflow, or string truncation|-Integer divide by zero. The code attempted to divide an integer value by an integer divisor of zero.'
REF='Statement failed, SQLSTATE = 42000|Dynamic SQL Error'

echo "--- 1. A FOR SELECT RUNS ITS BODY FOR EVERY ROW FETCHED BEFORE THE SOURCE RAISES"
pin  "1 WHEN EXCEPTION over a callee's raise after one row" "$(eb "EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN R = ''; BEGIN FOR SELECT R FROM PSEL(0) INTO :X DO R = R || X; WHEN EXCEPTION E_SIMPLE DO R = R || ' caught'; END SUSPEND; END")" "R|1 caught"
pin  "1 ...WHEN ANY" "$(eb "EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN R = ''; BEGIN FOR SELECT R FROM PSEL(0) INTO :X DO R = R || X; WHEN ANY DO R = R || ' any'; END SUSPEND; END")" "R|1 any"
pin  "1 a WHEN ANY counter over a source failing at its fourth row" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE Y INTEGER; BEGIN C = 0; BEGIN FOR SELECT X FROM PE4 INTO :Y DO C = C + 1; WHEN ANY DO C = C + 100; END SUSPEND; END')" "C|103"
pin  "1 ...ROW_COUNT read in the handler is the last good fetch" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE Y INTEGER; BEGIN C = 0; BEGIN FOR SELECT X FROM PE4 INTO :Y DO C = C + Y; WHEN ANY DO C = C + 1000; END SUSPEND; END')" "C|1017"
pin  "1 a selectable block suspending each fetched row" "$(eb 'EXECUTE BLOCK RETURNS (Y INTEGER) AS BEGIN FOR SELECT X FROM PE3 INTO :Y DO SUSPEND; END')" "Y|1|2|$DIV|-At procedure \"PUBLIC\".\"PE3\" line: 1, col: 83|At block line: 1, col: 44"
pin  "1 ...over a source whose fourth row divides by zero" "$(eb 'EXECUTE BLOCK RETURNS (Y INTEGER) AS BEGIN FOR SELECT X FROM PE4 INTO :Y DO SUSPEND; END')" "Y|2|5|10|$DIV|-At procedure \"PUBLIC\".\"PE4\" line: 1, col: 125|At block line: 1, col: 44"
pin  "1 a LEAVE at the first row never meets the raise" "$(eb "EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN R = ''; FOR SELECT R FROM PSEL(0) INTO :X DO BEGIN R = R || X; LEAVE; END SUSPEND; END")" "R|1"
pin  "1 ...a LEAVE at the second of three good rows" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE Y INTEGER; BEGIN C = 0; FOR SELECT X FROM PE4 INTO :Y DO BEGIN C = C + 1; IF (C = 2) THEN LEAVE; END SUSPEND; END')" "C|2"
pin  "1 uncaught, the non-selectable block raises after the body ran" "$(eb 'EXECUTE BLOCK AS DECLARE Y INTEGER; BEGIN FOR SELECT X FROM PE4 INTO :Y DO INSERT INTO LG VALUES (:Y); END')
SELECT COUNT(*) FROM LG;" "$DIV|-At procedure \"PUBLIC\".\"PE4\" line: 1, col: 125|At block line: 1, col: 43|COUNT|0"
pin  "1 ...WHEN ANY keeps the rows the body wrote" "$(eb 'EXECUTE BLOCK AS DECLARE Y INTEGER; BEGIN BEGIN FOR SELECT X FROM PE4 INTO :Y DO INSERT INTO LG VALUES (:Y); WHEN ANY DO BEGIN END END END')
SELECT COUNT(*), SUM(N) FROM LG; ROLLBACK;" "COUNT SUM|3 17"
pin  "1 CONTROL a source that does not raise" "$(eb "EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN R = ''; FOR SELECT R FROM PSEL(1) INTO :X DO R = R || X; SUSPEND; END")" "R|12"
pin  "1 CONTROL the procedure alone" "SELECT * FROM PE4;" "X|2|5|10|$DIV|-At procedure \"PUBLIC\".\"PE4\" line: 1, col: 125"

echo "--- 2. A TEXT ARGUMENT OBEYS AN INTEGER PARAMETER'S WIDTH (it answered 70000)"
pin  "2 '70000' into SMALLINT" "SELECT * FROM Q5('70000');" "R|$AR"
pin  "2 ...EXECUTE PROCEDURE" "EXECUTE PROCEDURE Q5('70000');" "$AR"
pin  "2 ...the body writes it on: still locationless" "SELECT * FROM PS('70000');" "R|$AR"
pin  "2 '-70000'" "SELECT * FROM Q5('-70000');" "R|$AR"
pin  "2 '32768'" "SELECT * FROM Q5('32768');" "R|$AR"
pin  "2 '3000000000' into INTEGER" "SELECT * FROM PI('3000000000');" "R|$AR"
pin  "2 CONTROL ' -32768 ' fits" "SELECT * FROM Q5(' -32768 ');" "R|-32768"
pin  "2 CONTROL '-2147483648' fits an INTEGER" "SELECT * FROM PI('-1073741824');" "R|-2147483648"
pin  "2 CONTROL the body's own overflow names the frame" "SELECT * FROM PS('32767');" "R|$AR|-At procedure \"PUBLIC\".\"PS\" line: 1, col: 64"
pin  "2 CONTROL 70000 as a number" "SELECT * FROM Q5(70000);" "R|$AR"

echo "--- 3. A TRIGGER'S LOCALS CONVERT INTO THEIR DECLARED TYPES"
pin  "3 NUMERIC(10,2) and CHAR(4) locals" "INSERT INTO TT (ID, V) VALUES (1, 1.005);
SELECT ID, V, W, S FROM TT WHERE ID = 1; ROLLBACK;" "ID V W S|1 1.0050 1.0100 ab |"
pin  "3 a negative value rounds away" "INSERT INTO TT (ID, V) VALUES (2, -2.345);
SELECT W FROM TT WHERE ID = 2; ROLLBACK;" "W|-2.3500"
pin  "3 70000 into a SMALLINT local fails the INSERT" "INSERT INTO TT (ID, V) VALUES (9, 1);
SELECT COUNT(*) FROM TT WHERE ID = 9; ROLLBACK;" "$AR|-At trigger \"PUBLIC\".\"TBI\" line: 1, col: 185|COUNT|0"
pin  "3 an exact value, the CHAR(4) local padded" "INSERT INTO TT (ID, V) VALUES (3, 7.25);
SELECT W, CHAR_LENGTH(S) FROM TT WHERE ID = 3; ROLLBACK;" "W CHAR_LENGTH|7.2500 5"

echo "--- 4. A FUNCTION'S FRAME ON THE BLR PATH (the 22003 came bare)"
pin  "4 RETURN overflows the SMALLINT result" "SELECT F3(33) FROM RDB\$DATABASE;" "F3|$AR|-At function \"PUBLIC\".\"F3\" line: 1, col: 58"
pin  "4 ...over a table's rows" "SELECT F3(ID * 11) FROM T WHERE ID = 4;" "F3|$AR|-At function \"PUBLIC\".\"F3\" line: 1, col: 58"
pin  "4 CONTROL in range" "SELECT F3(3) FROM RDB\$DATABASE;" "F3|3000"
pin  "4 CONTROL an argument past INTEGER is locationless" "SELECT F3(3000000000) FROM RDB\$DATABASE;" "F3|$AR"

echo "--- 5. EXECUTE PROCEDURE STOPS AT THE FIRST SUSPEND (it ran on into the raise)"
pin  "5 a row, then 1/0" "EXECUTE PROCEDURE PE3;" "X|1"
pin  "5 PE5(40): 40, then an overflow" "EXECUTE PROCEDURE PE5(40);" "X|40"
pin  "5 CONTROL PE5(40000): the overflow before the first SUSPEND" "EXECUTE PROCEDURE PE5(40000);" "$AR|-At procedure \"PUBLIC\".\"PE5\" line: 1, col: 64"
pin  "5 PE5(4000) answers its first row, never reaching 4000 * 1000" "EXECUTE PROCEDURE PE5(4000);" "X|4000"
pin  "5 a write after the first SUSPEND never happens" "EXECUTE PROCEDURE PL;
SELECT COUNT(*) FROM LG; ROLLBACK;" "X|1|COUNT|0"
pin  "5 CONTROL SELECT reads past it" "SELECT * FROM PE5(40);" "X|40|$AR|-At procedure \"PUBLIC\".\"PE5\" line: 1, col: 80"
pin  "5 CONTROL a body that raises after its first SUSPEND (the source path)" "EXECUTE PROCEDURE PSEL(0);" "R|1"

echo "--- 6. A BARE LOCAL IN A VALUE THE PLANNER ANSWERS IS THE LOCAL (these refused)"
pin  "6 NUMERIC local plus a decimal literal" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(9,2)) AS DECLARE X NUMERIC(9,2); BEGIN X = 1; R = X + 0.01; SUSPEND; END')" "R|1.01"
pin  "6 ...a NULL local" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(9,2)) AS DECLARE X NUMERIC(9,2); BEGIN R = X + 0.01; SUSPEND; END')" "R|<null>"
pin  "6 unary minus on a local" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE X SMALLINT; BEGIN X = 5; X = -X; R = X; SUSPEND; END')" "R|-5"
pin  "6 CHAR_LENGTH of a CHAR(3) local" "$(eb "EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X CHAR(3); BEGIN X = 'ab'; R = CHAR_LENGTH(X); SUSPEND; END")" "R|3"
pin  "6 OCTET_LENGTH of it" "$(eb "EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X CHAR(3); BEGIN X = 'ab'; R = OCTET_LENGTH(X); SUSPEND; END")" "R|3"
pin  "6 CHAR_LENGTH of a VARCHAR keeps its blanks" "$(eb "EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X VARCHAR(5); BEGIN X = 'ab  '; R = CHAR_LENGTH(X); SUSPEND; END")" "R|4"
pin  "6 a NUMERIC local times a decimal" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(9,3)) AS DECLARE X NUMERIC(9,2) = 2.5; BEGIN R = X * 1.5; SUSPEND; END')" "R|3.750"
pin  "6 COALESCE over a local plus a decimal, into an INTEGER" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X INTEGER = 3; BEGIN R = COALESCE(X, 0) + 0.4; SUSPEND; END')" "R|3"
pin  "6 a local named in lower case" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(9,2)) AS DECLARE x NUMERIC(9,2) = 1; BEGIN R = x + 0.25; SUSPEND; END')" "R|1.25"
pin  "6 a CAST(<integer> AS BIGINT) argument" "SELECT * FROM PI(CAST(5 AS BIGINT));" "R|10"
pin  "6 ...AS SMALLINT" "SELECT * FROM PI(CAST(5 AS SMALLINT));" "R|10"
pin  "6 ...EXECUTE PROCEDURE, AS INTEGER" "EXECUTE PROCEDURE PI(CAST(7 AS INTEGER));" "R|14"
pin  "6 ...a BIGINT past the INTEGER parameter" "SELECT * FROM PI(CAST(3000000000 AS BIGINT));" "R|$AR"
pin  "6 CONTROL a subquery keeps its colons" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X INTEGER = 3; BEGIN R = (SELECT COUNT(*) FROM RDB$DATABASE WHERE 1 = :X - 2) + 4; SUSPEND; END')" "R|5"
pin  "6 CONTROL a local concatenated with a text" "$(eb "EXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE X INTEGER = 3; BEGIN R = 'x' || X; SUSPEND; END")" "R|x3"

echo "--- 7. RECORDED"
# PROMOTED: a block compiles against the catalog now, functions included
pin  "7 a stored function called in a block (the procedure compiler refused it)" "$(eb 'EXECUTE BLOCK RETURNS (R SMALLINT) AS BEGIN R = F3(3); SUSPEND; END')" "R|3000"
pin  "7 ...its overflow" "$(eb 'EXECUTE BLOCK RETURNS (R SMALLINT) AS BEGIN R = F3(33); SUSPEND; END')" "R|$AR|-At function \"PUBLIC\".\"F3\" line: 1, col: 58|At block line: 1, col: 45"
pin "7 an INT128 local (promoted: dsql compiles INT128)" "$(eb 'EXECUTE BLOCK RETURNS (R INT128) AS DECLARE A INT128; BEGIN A = 170141183460469231731687303715884105727; R = A; SUSPEND; END')" "R|170141183460469231731687303715884105727"
pin "7 a NUMERIC(38,2) output (promoted)" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(38,2)) AS DECLARE A NUMERIC(18,2); BEGIN A = 1.01; R = A; SUSPEND; END')" "R|1.01"
pin     "7 a scaled literal past 32 bits" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(18,2)) AS DECLARE A NUMERIC(18,2); BEGIN A = 92233720368547758.07; R = A; SUSPEND; END')" "R|92233720368547758.07"
pin     "7 IIF over a local" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X INTEGER = 3; BEGIN R = IIF(X > 2, X * 10, 0); SUSPEND; END')" "R|30"
pin     "7 EXTRACT(DAY FROM D) over a local (it was a wrong -204 Table unknown \"D\")" "$(eb "EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE D DATE; BEGIN D = DATE '2026-09-26'; R = EXTRACT(DAY FROM D); SUSPEND; END")" "R|26"
differs "7 a WHERE over a procedure raising after a passing row" "SELECT * FROM PE5(40) WHERE X > 0;" "X|40|$AR|-At procedure \"PUBLIC\".\"PE5\" line: 1, col: 80" "X|$AR|-At procedure \"PUBLIC\".\"PE5\" line: 1, col: 80"
refused "7 UNION ALL over it" "SELECT X FROM PE5(40) UNION ALL SELECT 7 FROM RDB\$DATABASE;" "X|40|$AR|-At procedure \"PUBLIC\".\"PE5\" line: 1, col: 80"
differs "7 EXECUTE PROCEDURE with an empty argument list" "EXECUTE PROCEDURE PY0 ();" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 24|-)" "R|7"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-psqlfetch-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 58 ]; then echo "FAIL only $ran checks ran (floor 58)"; fail=1; fi
exit $fail
