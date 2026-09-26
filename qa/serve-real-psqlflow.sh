#!/bin/bash
# PSQL CONTROL FLOW: exception identity across a call, ROW_COUNT after a
# FOR SELECT, the rows a body suspended before it raised, the
# RETURNING_VALUES count, and a negative variable in a call's arguments.
#
# Measured on engine 2182 and matched:
#
#   * `WHEN EXCEPTION E_SIMPLE` catches E_SIMPLE raised INSIDE a called
#     procedure (EXECUTE PROCEDURE or SELECT ... FROM PX(0) INTO, and two
#     frames down); only `WHEN ANY` caught it here - the call handed the
#     exception back as a runtime error and the name match looked for a
#     local raise only;
#   * ROW_COUNT counts a FOR SELECT's fetches - 0 once it opens, the
#     running count after each fetch (a body summing it reads 1+2+...+5 =
#     15, a LEAVE at row 2 leaves 2), untouched by the fetch that finds
#     the end - where it read 0 after any loop. FOR EXECUTE STATEMENT
#     leaves it alone (0 after five rows), as it did;
#   * a selectable EXECUTE BLOCK that suspended rows and then raised
#     delivers those rows and then the error (it answered the error
#     alone), and so does a selectable procedure the BLR executor ran;
#   * `EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :R` over a
#     two-output procedure is the PREPARE-time 07002 "Output parameter
#     mismatch for procedure "PUBLIC"."P_EXEC"" - fewer, more, or none at
#     all - where this bound the first output and answered 8; a WHEN ANY
#     round it does not catch it, since nothing has run. A call naming no
#     procedure is the same prepare-time -204 the statement form gives;
#   * `SELECT R FROM PY(:I) INTO :R` with I = -2 answers -2: the variable
#     is spliced in as `(-2)`, which the argument reader refused and the
#     planner then misread as a relation, answering the -313 count
#     mismatch.
#
# RECORDED, not fixed: a WHERE over a procedure whose body raises after
# suspending delivers the error without the rows that passed the filter
# (the engine delivers row 2, then the error; this answered a bare
# Dynamic SQL Error before) - the rows are read as a set there, which has
# nowhere to put the error that follows them; and a
# call argument that is an EXPRESSION over a variable (`PY(:I - 1)`)
# refuses where the engine answers -3 (it answered -313 before).
#
# Usage: qa/serve-real-psqlflow.sh [port]   (default 5401)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5401}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/psqlflow-eng.fdb"; FC="$D/psqlflow-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T1 (ID INTEGER NOT NULL PRIMARY KEY);
INSERT INTO T1 VALUES (1); INSERT INTO T1 VALUES (2); INSERT INTO T1 VALUES (3); INSERT INTO T1 VALUES (4); INSERT INTO T1 VALUES (5);
CREATE EXCEPTION E_SIMPLE 'simple error';
CREATE EXCEPTION E_OTHER 'other';
SET TERM ^;
CREATE PROCEDURE PX (A INTEGER) RETURNS (R INTEGER) AS BEGIN IF (A = 0) THEN EXCEPTION E_SIMPLE 'zero!'; R = 100 / A; SUSPEND; END^
CREATE PROCEDURE PX2 (A INTEGER) RETURNS (R INTEGER) AS BEGIN EXECUTE PROCEDURE PX(A) RETURNING_VALUES :R; SUSPEND; END^
CREATE PROCEDURE P_EXEC (A INTEGER) RETURNS (R INTEGER, S VARCHAR(10)) AS BEGIN R = A * 2; S = 'v' || A; END^
CREATE PROCEDURE PY (A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A; SUSPEND; END^
CREATE PROCEDURE PE3 RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; X = 2; SUSPEND; X = 1/0; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/psqlflow-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/psqlflow-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/psqlflow-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-psqlflow-$PORT.log" 2>&1 & srv=$!
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
# one EXECUTE BLOCK (or any ^-terminated PSQL statement) as a script
eb() { printf 'SET TERM ^;\n%s^\nSET TERM ;^\n' "$1"; }
DUAL='FROM RDB$DATABASE'
AR='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
TR='Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation'
REF='Statement failed, SQLSTATE = 42000|Dynamic SQL Error'

# RECORDED: both raise the SAME error, but the engine delivers rows first
# that this server does not. Fails the day they agree.
rows_dropped() { # <label> <script> <engine-output> <this-server-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THE ROWS NOW ARRIVE; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server answers [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: the engine [$ev], this server [$fv])"; fi
}
UEX='Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-zero!|-At procedure "PUBLIC"."PX" line: 1, col: 78'
DIV='Statement failed, SQLSTATE = 22012|arithmetic exception, numeric overflow, or string truncation|-Integer divide by zero. The code attempted to divide an integer value by an integer divisor of zero.'
MIS='Statement failed, SQLSTATE = 07002|Dynamic SQL Error|-Output parameter mismatch for procedure "PUBLIC"."P_EXEC"'

echo "--- 1. WHEN EXCEPTION <name> CATCHES THAT EXCEPTION RAISED IN A CALLEE"
pin  "1 EXECUTE PROCEDURE (the error escaped)" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN EXCEPTION E_SIMPLE DO M = 1; END SUSPEND; END')" "R M|<null> 1"
pin  "1 SELECT ... FROM PX(0) INTO" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN SELECT R FROM PX(0) INTO :R; WHEN EXCEPTION E_SIMPLE DO M = 1; END SUSPEND; END')" "R M|<null> 1"
pin  "1 two frames down" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX2(0) RETURNING_VALUES :R; WHEN EXCEPTION E_SIMPLE DO M = 5; END SUSPEND; END')" "R M|<null> 5"
pin  "1 lower case in the handler" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN EXCEPTION e_simple DO M = 1; END SUSPEND; END')" "R M|<null> 1"
pin  "1 CONTROL another exception's handler lets it through, both frames named" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN EXCEPTION E_OTHER DO M = 4; END SUSPEND; END')" "R M|$UEX|At block line: 1, col: 68"
pin  "1 a bare EXCEPTION; in the handler re-raises it with its own frame" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN EXCEPTION E_SIMPLE DO BEGIN M = 6; EXCEPTION; END END SUSPEND; END')" "R M|$UEX|At block line: 1, col: 68|-At block line: 1, col: 153"
pin  "1 CONTROL WHEN ANY" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN ANY DO M = 1; END SUSPEND; END')" "R M|<null> 1"
pin  "1 CONTROL WHEN GDSCODE EXCEPT" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN GDSCODE EXCEPT DO M = 2; END SUSPEND; END')" "R M|<null> 2"
pin  "1 CONTROL WHEN SQLCODE -836" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, M INTEGER) AS BEGIN M = 0; BEGIN EXECUTE PROCEDURE PX(0) RETURNING_VALUES :R; WHEN SQLCODE -836 DO M = 3; END SUSPEND; END')" "R M|<null> 3"
pin  "1 CONTROL the local raise" "$(eb 'EXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN M = 0; BEGIN EXCEPTION E_SIMPLE; WHEN EXCEPTION E_SIMPLE DO M = 7; END SUSPEND; END')" "M|7"

echo "--- 2. ROW_COUNT AFTER A FOR SELECT (it read 0)"
pin  "2 five rows fetched" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN FOR SELECT ID FROM T1 INTO :X DO BEGIN END C = ROW_COUNT; SUSPEND; END')" "C|5"
pin  "2 the running count inside the body sums to 15" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN C = 0; FOR SELECT ID FROM T1 INTO :X DO BEGIN C = C + ROW_COUNT; END SUSPEND; END')" "C|15"
pin  "2 a LEAVE at the second row leaves 2" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN FOR SELECT ID FROM T1 INTO :X DO BEGIN IF (X = 2) THEN LEAVE; END C = ROW_COUNT; SUSPEND; END')" "C|2"
pin  "2 the end-of-cursor fetch leaves the body's UPDATE count" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN FOR SELECT ID FROM T1 INTO :X DO BEGIN UPDATE T1 SET ID = ID WHERE ID = 1; END C = ROW_COUNT; SUSPEND; END')" "C|1"
pin  "2 an empty FOR resets an earlier UPDATE's 5 to 0" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN UPDATE T1 SET ID = ID; FOR SELECT ID FROM T1 WHERE ID > 10 INTO :X DO BEGIN END C = ROW_COUNT; SUSPEND; END')" "C|0"
pin  "2 CONTROL an empty FOR" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN FOR SELECT ID FROM T1 WHERE ID > 10 INTO :X DO BEGIN END C = ROW_COUNT; SUSPEND; END')" "C|0"
pin  "2 CONTROL FOR EXECUTE STATEMENT leaves it alone" "$(eb "EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN FOR EXECUTE STATEMENT 'SELECT ID FROM T1' INTO :X DO BEGIN END C = ROW_COUNT; SUSPEND; END")" "C|0"
pin  "2 CONTROL a singleton SELECT INTO" "$(eb 'EXECUTE BLOCK RETURNS (C INTEGER) AS DECLARE X INTEGER; BEGIN SELECT ID FROM T1 WHERE ID = 3 INTO :X; C = ROW_COUNT; SUSPEND; END')" "C|1"

echo "--- 3. THE ROWS SUSPENDED BEFORE A RAISE ARE DELIVERED, THEN THE ERROR (the error came alone)"
pin  "3 a block: one row, then 1/0" "$(eb 'EXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; X = 1/0; SUSPEND; END')" "X|1|$DIV|-At block line: 1, col: 60"
pin  "3 a block: two rows, then a user exception" "$(eb 'EXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; X = 2; SUSPEND; EXCEPTION E_SIMPLE; END')" "X|1|2|Statement failed, SQLSTATE = HY000|exception 1|-\"PUBLIC\".\"E_SIMPLE\"|-simple error|-At block line: 1, col: 76"
pin  "3 a block: two rows, then a 22003 conversion" "$(eb 'EXECUTE BLOCK RETURNS (X SMALLINT) AS BEGIN X = 1; SUSPEND; X = 2; SUSPEND; X = 70000; SUSPEND; END')" "X|1|2|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|-At block line: 1, col: 77"
pin  "3 a procedure the BLR executor runs" "SELECT * FROM PE3;" "X|1|2|$DIV|-At procedure \"PUBLIC\".\"PE3\" line: 1, col: 83"
pin  "3 ...a column list over it" "SELECT X FROM PE3;" "X|1|2|$DIV|-At procedure \"PUBLIC\".\"PE3\" line: 1, col: 83"
pin  "3 CONTROL FIRST 1 stops the body before the raise" "SELECT FIRST 1 * FROM PE3;" "X|1"
pin  "3 CONTROL FIRST 3 delivers both, then raises" "SELECT FIRST 3 * FROM PE3;" "X|1|2|$DIV|-At procedure \"PUBLIC\".\"PE3\" line: 1, col: 83"
rows_dropped "3 a WHERE over it drops the passing row" "SELECT * FROM PE3 WHERE X > 1;" "X|2|$DIV|-At procedure \"PUBLIC\".\"PE3\" line: 1, col: 83" "X|$DIV|-At procedure \"PUBLIC\".\"PE3\" line: 1, col: 83"

echo "--- 4. RETURNING_VALUES MUST NAME EVERY OUTPUT - a PREPARE-time 07002 (it answered 8)"
pin  "4 one target for two outputs" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :R; SUSPEND; END')" "$MIS"
pin  "4 no target at all" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN EXECUTE PROCEDURE P_EXEC(4); R = 1; SUSPEND; END')" "$MIS"
pin  "4 three targets" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE A INTEGER; DECLARE B VARCHAR(10); DECLARE C INTEGER; BEGIN EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :A, :B, :C; R = 1; SUSPEND; END')" "$MIS"
pin  "4 a WHEN ANY round it does not catch it" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = 0; BEGIN EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :R; WHEN ANY DO R = 9; END SUSPEND; END')" "$MIS"
pin  "4 ...nor does code before it run" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = 5; SUSPEND; EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :R; END')" "$MIS"
pin  "4 a non-selectable block too" "$(eb 'EXECUTE BLOCK AS DECLARE R INTEGER; BEGIN EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :R; END')" "$MIS"
pin  "4 CONTROL both targets" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE A INTEGER; DECLARE B VARCHAR(10); BEGIN EXECUTE PROCEDURE P_EXEC(4) RETURNING_VALUES :A, :B; R = A; SUSPEND; END')" "R|8"
pin  "4 CONTROL a one-output procedure" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE A INTEGER; BEGIN EXECUTE PROCEDURE PY(1) RETURNING_VALUES :A; R = A; SUSPEND; END')" "R|1"
pin  "4 a call naming no procedure is the prepare-time -204" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN EXECUTE PROCEDURE NOSUCHPROC RETURNING_VALUES :R; SUSPEND; END')" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"NOSUCHPROC\""
pin  "4 ...in a non-selectable block" "$(eb 'EXECUTE BLOCK AS BEGIN EXECUTE PROCEDURE NOSUCHPROC; END')" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"NOSUCHPROC\""

echo "--- 5. A NEGATIVE VARIABLE IN A CALL'S ARGUMENTS (-313)"
pin  "5 SELECT R FROM PY(:I) INTO :R, I = -2" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE I INTEGER = -2; BEGIN SELECT R FROM PY(:I) INTO :R; SUSPEND; END')" "R|-2"
pin  "5 ...FOR SELECT over it" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE I INTEGER = -2; BEGIN FOR SELECT R FROM PY(:I) INTO :R DO SUSPEND; END')" "R|-2"
pin  "5 ...a NUMERIC(5,2) -2.5 into the INTEGER parameter rounds away" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(5,2)) AS DECLARE I NUMERIC(5,2) = -2.5; BEGIN SELECT R FROM PY(:I) INTO :R; SUSPEND; END')" "R|-3.00"
pin  "5 a parenthesised literal argument" "SELECT R FROM PY((-2));" "R|-2"
pin  "5 ...(2)" "SELECT R FROM PY((2));" "R|2"
pin  "5 ...(-2.5)" "SELECT R FROM PY((-2.5));" "R|-3"
pin  "5 ...EXECUTE PROCEDURE PY((-2))" "EXECUTE PROCEDURE PY((-2));" "R|-2"
pin  "5 CONTROL a positive variable" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE I INTEGER = 2; BEGIN SELECT R FROM PY(:I) INTO :R; SUSPEND; END')" "R|2"
pin  "5 CONTROL 5 - :I" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE I INTEGER = -2; BEGIN SELECT 5 - :I FROM RDB$DATABASE INTO :R; SUSPEND; END')" "R|7"
refused "5 an argument EXPRESSION over the variable" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE I INTEGER = -2; BEGIN SELECT R FROM PY(:I - 1) INTO :R; SUSPEND; END')" "R|-3"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-psqlflow-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 45 ]; then echo "FAIL only $ran checks ran (floor 45)"; fail=1; fi
exit $fail
