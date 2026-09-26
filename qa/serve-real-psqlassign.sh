#!/bin/bash
# A PSQL ASSIGNMENT CONVERTS INTO THE TARGET'S DECLARED TYPE.
#
# The engine's PSQL assignment is MOV_move into the target's descriptor -
# the very move a CAST makes - for a local variable, an output parameter,
# a DECLARE initialiser, a SELECT/FETCH/FOR SELECT INTO slot and a
# RETURNING_VALUES target alike. This server's frame held bare values
# with no declared type beside them, so every one of these went in
# unconverted and came out wrong:
#
#   * `R = 3` into a NUMERIC(10,2) output answered 0.03 (the integer left
#     as the raw of a scale-2 slot), `R = 2.5` into an INTEGER 25, 1.005
#     into NUMERIC(10,2) 10.05, `A / B` over a NUMERIC(5,1) local 3 for
#     3.5 - and `SELECT FIRST 1 * FROM PNUM2` 0.03 where the bare select
#     (the BLR path, which did convert) answered 3.00;
#   * 3000000000 into an INTEGER wrapped to -1294967296 and 32767 + 1 into
#     a SMALLINT answered 32768, where the engine raises 22003 at the
#     assignment's line and column;
#   * a VARCHAR(3) local held 'abcdef' where the engine raises 22001, a
#     CHAR(5) local holding 'ab' concatenated as 'ab|' for 'ab   |';
#   * 123456 into a VARCHAR(5) raised 22001 where a number rendered into
#     too short a text is the 22018 conversion error.
#
# Around them, measured and matched: a SMALLINT procedure argument out of
# range is the engine's LOCATIONLESS 22003 (the conversion happens at the
# call boundary); a stored FUNCTION's frame reads `At function`, not `At
# procedure`; `EXECUTE PROCEDURE NOSUCHPROC` is -204 Procedure unknown
# naming the procedure as written, not a bare Dynamic SQL Error.
#
# RECORDED, not fixed (both still refuse, the engine answers): a local
# declared by DOMAIN or TYPE OF COLUMN keeps the untyped store, so the
# body refuses rather than guessing the conversion; DOUBLE PRECISION /
# DATE arithmetic on a local, `DECLARE ... DEFAULT <decimal>`, an
# integer local times a decimal literal, and FLOAT / DOUBLE / BOOLEAN /
# TIMESTAMP outputs of an EXECUTE BLOCK are outside the interpreter's
# surface as they were before - clean refusals, pinned as such below.
#
# Usage: qa/serve-real-psqlassign.sh [port]   (default 5400)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5400}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/psqlassign-eng.fdb"; FC="$D/psqlassign-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T2 (ID INTEGER, N NUMERIC(10,3), S VARCHAR(10), C CHAR(4));
INSERT INTO T2 VALUES (1, 2.255, 'hello', 'ab');
INSERT INTO T2 VALUES (2, 7.5, 'x', 'wxyz');
CREATE DOMAIN DNUM AS NUMERIC(10,2);
SET TERM ^;
CREATE PROCEDURE PNUM2 RETURNS (R NUMERIC(10,2)) AS BEGIN R = 3; SUSPEND; END^
CREATE PROCEDURE Q5 (A SMALLINT) RETURNS (R INTEGER) AS BEGIN R = A; SUSPEND; END^
CREATE PROCEDURE Q2 RETURNS (R VARCHAR(20)) AS DECLARE X VARCHAR(3); BEGIN X = 'abcdefg'; R = X; SUSPEND; END^
CREATE PROCEDURE Q1 RETURNS (R VARCHAR(20)) AS DECLARE X CHAR(5); BEGIN X = 'ab'; R = X || '|'; SUSPEND; END^
CREATE PROCEDURE PN2 (A INTEGER) RETURNS (R SMALLINT) AS BEGIN R = A; SUSPEND; END^
CREATE PROCEDURE PN3 (A NUMERIC(5,2)) RETURNS (R NUMERIC(5,2), S VARCHAR(10)) AS BEGIN R = A; S = A; SUSPEND; END^
CREATE PROCEDURE PN4 (A INTEGER) RETURNS (R NUMERIC(4,2)) AS BEGIN R = A; SUSPEND; END^
CREATE PROCEDURE PN5 RETURNS (R INTEGER) AS DECLARE X NUMERIC(10,2); BEGIN SELECT N FROM T2 WHERE ID = 1 INTO :X; R = X * 100; SUSPEND; END^
CREATE PROCEDURE PN6 RETURNS (R VARCHAR(20)) AS DECLARE X SMALLINT; BEGIN FOR SELECT ID * 20000 FROM T2 INTO :X DO R = X; SUSPEND; END^
CREATE FUNCTION G6F (A INTEGER) RETURNS VARCHAR(5) AS BEGIN RETURN A; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/psqlassign-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/psqlassign-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/psqlassign-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-psqlassign-$PORT.log" 2>&1 & srv=$!
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

echo "--- 1. AN EXACT NUMERIC TAKES THE TARGET'S SCALE"
pin  "1 an integer into a NUMERIC(10,2) output (0.03)" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(10,2)) AS BEGIN R = 3; SUSPEND; END')" "R|3.00"
pin  "1 2.5 into an INTEGER output rounds away (25)" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = 2.5; SUSPEND; END')" "R|3"
pin  "1 -2.5 into an INTEGER rounds away too" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = -2.5; SUSPEND; END')" "R|-3"
pin  "1 1.005 into NUMERIC(10,2) (10.05)" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(10,2)) AS BEGIN R = 1.005; SUSPEND; END')" "R|1.01"
pin  "1 2.5 into a BIGINT output" "$(eb 'EXECUTE BLOCK RETURNS (R BIGINT) AS BEGIN R = 2.5; SUSPEND; END')" "R|3"
pin  "1 1 into NUMERIC(18,4)" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(18,4)) AS BEGIN R = 1; SUSPEND; END')" "R|1.0000"
pin  "1 a BIGINT over a NUMERIC(5,1) LOCAL divides at scale (3)" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE A BIGINT = 7; DECLARE B NUMERIC(5,1) = 2; BEGIN R = A / B; SUSPEND; END')" "R|3.5"
pin  "1 a NUMERIC(10,2) local holds 7.00 (7)" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE A NUMERIC(10,2); BEGIN A = 7; R = A; SUSPEND; END')" "R|7.00"
pin  "1 the DECLARE initialiser converts" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X NUMERIC(10,2) = 1; BEGIN R = X; SUSPEND; END')" "R|1.00"
pin  "1 NUMERIC(4,2) rounds 123.456 and 99.995 up to 100.00" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30), S VARCHAR(30)) AS DECLARE X NUMERIC(4,2); BEGIN X = 123.456; R = X; X = 99.995; S = X; SUSPEND; END')" "R S|123.46 100.00"
pin  "1 CONTROL a NULL passes into any type" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER, S NUMERIC(10,2)) AS BEGIN R = NULL; S = NULL; SUSPEND; END')" "R S|<null> <null>"
dsame "1 describe of a NUMERIC(10,2) block output" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(10,2)) AS BEGIN R = 3; SUSPEND; END')"

echo "--- 2. A VALUE PAST THE TARGET'S WIDTH RAISES 22003 AT THE ASSIGNMENT (it wrapped)"
pin  "2 3000000000 into an INTEGER output (-1294967296)" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = 3000000000; SUSPEND; END')" "R|$AR|-At block line: 1, col: 44"
pin  "2 32767 + 1 into a SMALLINT local (32768)" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X SMALLINT = 32767; BEGIN X = X + 1; R = X; SUSPEND; END')" "R|$AR|-At block line: 1, col: 72"
pin  "2 40000 into a SMALLINT output" "$(eb 'EXECUTE BLOCK RETURNS (R SMALLINT) AS BEGIN R = 40000; SUSPEND; END')" "R|$AR|-At block line: 1, col: 45"
pin  "2 a procedure's SMALLINT output from an INTEGER input names the procedure" "SELECT * FROM PN2(100000);" "R|$AR|-At procedure \"PUBLIC\".\"PN2\" line: 1, col: 64"
pin  "2 CONTROL the same procedure in range" "SELECT * FROM PN2(7);" "R|7"
pin  "2 FOR SELECT into a SMALLINT local, the second row overflows" "SELECT * FROM PN6;" "R|$AR|-At procedure \"PUBLIC\".\"PN6\" line: 1, col: 75"
pin  "2 a NUMERIC(4,2) output from INTEGER 400 (a SMALLINT raw of 40000)" "SELECT * FROM PN4(400);" "R|$AR|-At procedure \"PUBLIC\".\"PN4\" line: 1, col: 68"
pin  "2 CONTROL ...and from 100 (10000 fits)" "SELECT * FROM PN4(100);" "R|100.00"

echo "--- 3. TEXT: the width is enforced, CHAR pads, a number that does not fit is 22018"
pin  "3 'abcdef' into a VARCHAR(3) local (it held it)" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE X VARCHAR(3); BEGIN X = '"'abcdef'"'; R = X; SUSPEND; END')" "R|$TR|-expected length 3, actual 6|-At block line: 1, col: 70"
pin  "3 ...in a stored procedure" "SELECT * FROM Q2;" "R|$TR|-expected length 3, actual 7|-At procedure \"PUBLIC\".\"Q2\" line: 1, col: 76"
pin  "3 trailing blanks past the width are dropped, not an error" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X VARCHAR(3); BEGIN X = '"'abc   '"'; R = X || '"'|'"'; SUSPEND; END')" "R|abc|"
pin  "3 a CHAR(5) local pads before a concatenation ('ab|')" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE X CHAR(5); BEGIN X = '"'ab'"'; R = X || '"'|'"'; SUSPEND; END')" "R|ab |"
pin  "3 ...and in a stored procedure" "SELECT * FROM Q1;" "R|ab |"
pin  "3 OCTET_LENGTH of a CHAR(5) local is 5 (2)" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X CHAR(5) = '"'ab'"'; BEGIN SELECT OCTET_LENGTH(:X) FROM RDB$DATABASE INTO :R; SUSPEND; END')" "R|5"
pin  "3 123456 into a VARCHAR(5) output is 22018 (it was 22001)" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(5)) AS BEGIN R = 123456; SUSPEND; END')" "R|Statement failed, SQLSTATE = 22018|conversion error from string \"123456\"|-At block line: 1, col: 47"
pin  "3 12.345 into a VARCHAR(5) is 22018 too" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(5)) AS BEGIN R = 12.345; SUSPEND; END')" "R|Statement failed, SQLSTATE = 22018|conversion error from string \"12.345\"|-At block line: 1, col: 47"
pin  "3 ...and a stored FUNCTION's RETURN, framed At function" "SELECT G6F(123456) $DUAL;" "G6F|Statement failed, SQLSTATE = 22018|conversion error from string \"123456\"|-At function \"PUBLIC\".\"G6F\" line: 1, col: 61"
pin  "3 CONTROL the function in range" "SELECT G6F(12) $DUAL;" "G6F|12"
pin  "3 a text integer converts into an INTEGER local" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN X = '"'12'"'; R = X + 1; SUSPEND; END')" "R|13"
pin  "3 ...a non-number is 22018 at the assignment" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN X = '"'x1'"'; R = X; SUSPEND; END')" "R|Statement failed, SQLSTATE = 22018|conversion error from string \"x1\"|-At block line: 1, col: 67"
pin  "3 a text into a DATE output" "$(eb 'EXECUTE BLOCK RETURNS (R DATE) AS BEGIN R = '"'2020-01-02'"'; SUSPEND; END')" "R|2020-01-02"
pin  "3 CONTROL a CHAR(5) output sent directly" "$(eb 'EXECUTE BLOCK RETURNS (R CHAR(5)) AS BEGIN R = '"'ab'"'; SUSPEND; END')" "R|ab"

echo "--- 4. THE INTO SLOTS CONVERT TOO"
pin  "4 SELECT a NUMERIC(10,3) INTO an INTEGER local" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X INTEGER; BEGIN SELECT N FROM T2 WHERE ID = 1 INTO :X; R = X; SUSPEND; END')" "R|2"
pin  "4 SELECT a VARCHAR INTO a CHAR(6) local pads" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X CHAR(6); BEGIN SELECT S FROM T2 WHERE ID = 2 INTO :X; R = X || '"'|'"'; SUSPEND; END')" "R|x |"
pin  "4 SELECT a 5-character text INTO a VARCHAR(3) local" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X VARCHAR(3); BEGIN SELECT S FROM T2 WHERE ID = 1 INTO :X; R = X; SUSPEND; END')" "R|$TR|-expected length 3, actual 5|-At block line: 1, col: 70"
pin  "4 FOR SELECT into an INTEGER local sums the ROUNDED values (9755)" "$(eb 'EXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X INTEGER; BEGIN R = 0; FOR SELECT N FROM T2 INTO :X DO R = R + X; SUSPEND; END')" "R|10"
pin  "4 FOR SELECT into NUMERIC(10,3), out through NUMERIC(10,2)" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(10,2)) AS DECLARE X NUMERIC(10,3); BEGIN FOR SELECT N FROM T2 INTO :X DO BEGIN R = X; SUSPEND; END END')" "R|2.26|7.50"
pin  "4 SELECT INTO a NUMERIC(10,2) local in a procedure" "SELECT * FROM PN5;" "R|226"

echo "--- 5. PROCEDURE ARGUMENTS AND THE LIMITED-SELECT PATH"
pin  "5 CONTROL a plain select of PNUM2" "SELECT * FROM PNUM2;" "R|3.00"
pin  "5 FIRST 1 over PNUM2 (0.03)" "SELECT FIRST 1 * FROM PNUM2;" "R|3.00"
pin  "5 ROWS 1 over PNUM2" "SELECT * FROM PNUM2 ROWS 1;" "R|3.00"
pin  "5 FETCH FIRST / OFFSET over PNUM2" "SELECT * FROM PNUM2 OFFSET 0 ROWS FETCH FIRST 1 ROW ONLY;" "R|3.00"
pin  "5 a SMALLINT argument out of range, LOCATIONLESS (it answered 70000)" "SELECT * FROM Q5(70000);" "R|$AR"
pin  "5 CONTROL ...in range" "SELECT * FROM Q5(7);" "R|7"
pin  "5 NUMERIC(5,2) argument and output, and its text" "SELECT * FROM PN3(3);" "R S|3.00 3.00"
pin  "5 ...a finer argument rounds" "SELECT * FROM PN3(1.005);" "R S|1.01 1.01"
pin  "5 ...FIRST 1 over it" "SELECT FIRST 1 * FROM PN3(3);" "R S|3.00 3.00"
pin  "5 ...EXECUTE PROCEDURE" "EXECUTE PROCEDURE PN3(2);" "R S|2.00 2.00"

echo "--- 6. AN UNKNOWN PROCEDURE IS -204 Procedure unknown, named as written (a bare Dynamic SQL Error)"
pin  "6 EXECUTE PROCEDURE NOSUCHPROC" "EXECUTE PROCEDURE NOSUCHPROC;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"NOSUCHPROC\""
pin  "6 ...with arguments" "EXECUTE PROCEDURE NOSUCHPROC(1, 2);" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"NOSUCHPROC\""
pin  "6 ...qualified" "EXECUTE PROCEDURE PUBLIC.NOSUCHPROC;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"PUBLIC\".\"NOSUCHPROC\""
pin  "6 ...quoted lower case" "EXECUTE PROCEDURE \"nosuchproc\";" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"nosuchproc\""
pin  "6 ...a foreign package qualifier" "EXECUTE PROCEDURE NOPKG.NOSUCHPROC;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -204|-Procedure unknown|-\"NOPKG\".\"NOSUCHPROC\""

echo "--- 7. RECORDED: still refused where the engine answers (a clean refusal, never a wrong value)"
refused "7 a local declared by a DOMAIN" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X DNUM; BEGIN X = 1.005; R = X; SUSPEND; END')" "R|1.01"
refused "7 a local declared TYPE OF COLUMN" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X TYPE OF COLUMN T2.N; BEGIN X = 1.0005; R = X; SUSPEND; END')" "R|1.001"
refused "7 DOUBLE PRECISION arithmetic on a local" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X DOUBLE PRECISION; BEGIN X = 1; R = X / 3; SUSPEND; END')" "R|0.3333333333333333"
refused "7 DECLARE ... DEFAULT a decimal" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X NUMERIC(10,2) DEFAULT 2.345; BEGIN R = X; SUSPEND; END')" "R|2.35"
refused "7 an integer local times a decimal literal" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(10,2)) AS DECLARE X INTEGER = 3; BEGIN R = X * 1.001; SUSPEND; END')" "R|3.00"
refused "7 a DOUBLE PRECISION output" "$(eb 'EXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS BEGIN R = 2.5; SUSPEND; END')" "R|2.500000000000000"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-psqlassign-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 60 ]; then echo "FAIL only $ran checks ran (floor 60)"; fail=1; fi
exit $fail
