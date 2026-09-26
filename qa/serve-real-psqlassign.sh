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
# DATE arithmetic on a local, `DECLARE ... DEFAULT <decimal>`, and
# FLOAT / DOUBLE / BOOLEAN /
# TIMESTAMP outputs of an EXECUTE BLOCK are outside the interpreter's
# surface as they were before - clean refusals, pinned as such below.
# (An integer local times a decimal literal was recorded here too; it
# answers since the bare local is bound into the planner's value -
# qa/serve-real-psqlfetch.sh - and is pinned in 6b.)
#
# SECTION 8 - NON-ASCII TEXT THROUGH PSQL SLOTS, under the attachment a
# default isql opens (charset NONE, where a literal 'é' is the octets
# C3 A9). Every cell below that answered did so WRONGLY before:
#
#   * a stored body's SOURCE is not its BLR. Created under NONE, the
#     engine writes a '?' into RDB$PROCEDURE_SOURCE for each octet it
#     could not transliterate - `R = LPAD(X, L, 'é')` is stored as
#     `LPAD(X, L, '??')` - and runs the BLR, which keeps the octets. The
#     interpreter read the source and answered '???ab' for 'éééab',
#     '??b' for 'éb'. Such a body now refuses (8a); a genuine '?' that
#     the BLR carries verbatim still answers.
#   * an argument was bound in the representation it ARRIVED in - under
#     NONE one char per octet - whatever set its parameter declared, so a
#     UTF8 parameter holding 'é' was two characters: UPPER 'Ã©', X || '-'
#     || X 'Ã©-Ã©', SUBSTRING 'ãã', CHAR_LENGTH 2, and an eleven
#     character argument passed a VARCHAR(10) that was measured in bytes.
#     It is moved into the parameter's set now, as the engine's MOV does,
#     and every text slot holds its value in its own set: a variable
#     written into planner text is written TYPED when its set is not the
#     attachment's, a stored value moves into the slot's set (a UTF8 'Ω'
#     into WIN1252 is the 22018 at the assignment), and the BLR executor
#     - which carries no sets at all - is left to ASCII (8b, 8c).
#   * the statement-text rewriters copied a non-ASCII character octet by
#     octet as characters of its own: an EXECUTE BLOCK's 'é' into a NONE
#     output was four octets (8d); and a UTF8 operand || a NONE literal
#     glued the literal's carrier characters on ('éÃ©' for 'éé', 8e).
#
# RECORDED in section 8 (the engine answers, this server refuses): the
# lost-literal bodies; OVERLAY; a stored FUNCTION over non-ASCII text; a
# procedure CALLED from a body's query with a non-ASCII variable; an
# EXECUTE STATEMENT built from one; and the EXECUTE BLOCKs whose RETURNS
# or locals name a CHARACTER SET (the block compiler refuses them).
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
CREATE TABLE XTU (ID INTEGER, C VARCHAR(20) CHARACTER SET UTF8, W VARCHAR(20) CHARACTER SET WIN1252, N VARCHAR(20));
INSERT INTO XTU VALUES (1, 'é', 'é', 'é');
CREATE TABLE XTT (ID INTEGER, C VARCHAR(20) CHARACTER SET UTF8, W VARCHAR(20) CHARACTER SET WIN1252, N VARCHAR(20));
SET TERM ^;
CREATE PROCEDURE XPP (X VARCHAR(10) CHARACTER SET UTF8, L INTEGER) RETURNS (R VARCHAR(100) CHARACTER SET UTF8) AS BEGIN R = LPAD(X, L, 'é'); SUSPEND; END^
CREATE PROCEDURE XPS (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(100) CHARACTER SET UTF8) AS BEGIN R = REPLACE(X, 'a', 'é'); SUSPEND; END^
CREATE PROCEDURE XPQ (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(100) CHARACTER SET UTF8) AS BEGIN R = REPLACE(X, 'a', '?'); SUSPEND; END^
CREATE PROCEDURE XPU (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = UPPER(X); SUSPEND; END^
CREATE PROCEDURE XPLO (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = LOWER(X); SUSPEND; END^
CREATE PROCEDURE XPSB (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = SUBSTRING(X FROM 2 FOR 2); SUSPEND; END^
CREATE PROCEDURE XPCT (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(30) CHARACTER SET UTF8) AS BEGIN R = X || '-' || X; SUSPEND; END^
CREATE PROCEDURE XPLN (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (N INTEGER, O INTEGER) AS BEGIN N = CHAR_LENGTH(X); O = OCTET_LENGTH(X); SUSPEND; END^
CREATE PROCEDURE XPOV (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = OVERLAY(X PLACING 'Z' FROM 2 FOR 1); SUSPEND; END^
CREATE PROCEDURE XPRP (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = RPAD(X, 4, '*'); SUSPEND; END^
CREATE PROCEDURE XPLP (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = LPAD(X, 4, '*'); SUSPEND; END^
CREATE PROCEDURE XPRE (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = REPLACE(X, 'a', 'b'); SUSPEND; END^
CREATE PROCEDURE XPID (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = X; SUSPEND; END^
CREATE PROCEDURE XPW (X VARCHAR(10) CHARACTER SET WIN1252) RETURNS (R VARCHAR(20) CHARACTER SET WIN1252, N INTEGER) AS BEGIN R = UPPER(X); N = CHAR_LENGTH(X); SUSPEND; END^
CREATE PROCEDURE XPN (X VARCHAR(10)) RETURNS (R VARCHAR(20), N INTEGER) AS BEGIN R = UPPER(X); N = CHAR_LENGTH(X); SUSPEND; END^
CREATE PROCEDURE XPNU (X VARCHAR(10)) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = UPPER(X); SUSPEND; END^
CREATE PROCEDURE XPUW (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET WIN1252) AS BEGIN R = UPPER(X); SUSPEND; END^
CREATE PROCEDURE XPUN (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20), N INTEGER) AS BEGIN R = UPPER(X); N = CHAR_LENGTH(R); SUSPEND; END^
CREATE PROCEDURE XPLV (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS DECLARE V VARCHAR(10) CHARACTER SET WIN1252; BEGIN V = UPPER(X); R = LOWER(V); N = OCTET_LENGTH(V); SUSPEND; END^
CREATE PROCEDURE XPLN2 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20), N INTEGER) AS DECLARE V VARCHAR(10); BEGIN V = UPPER(X); R = V; N = CHAR_LENGTH(V); SUSPEND; END^
CREATE PROCEDURE XPIN (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (N INTEGER) AS BEGIN INSERT INTO XTT (ID, C) VALUES (9, UPPER(:X)); SELECT CHAR_LENGTH(C) FROM XTT WHERE ID = 9 INTO :N; SUSPEND; END^
CREATE PROCEDURE XPSEL (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN SELECT UPPER(:X) FROM RDB$DATABASE INTO :R; SUSPEND; END^
CREATE PROCEDURE XPIF (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (N INTEGER) AS BEGIN N = 0; IF (UPPER(X) = X) THEN N = 1; SUSPEND; END^
CREATE PROCEDURE XPWH (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (N INTEGER) AS DECLARE I INTEGER = 0; BEGIN N = 0; WHILE (I < CHAR_LENGTH(X)) DO BEGIN I = I + 1; N = N + 1; END SUSPEND; END^
CREATE PROCEDURE XFS1 RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN FOR SELECT C FROM XTU INTO :R DO BEGIN N = CHAR_LENGTH(R); SUSPEND; END END^
CREATE PROCEDURE XFS2 RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN FOR SELECT W FROM XTU INTO :R DO BEGIN N = CHAR_LENGTH(R); SUSPEND; END END^
CREATE PROCEDURE XFS3 RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN FOR SELECT N FROM XTU INTO :R DO BEGIN N = CHAR_LENGTH(R); SUSPEND; END END^
CREATE PROCEDURE XFS4 RETURNS (R VARCHAR(20), N INTEGER) AS BEGIN FOR SELECT C FROM XTU INTO :R DO BEGIN N = OCTET_LENGTH(R); SUSPEND; END END^
CREATE PROCEDURE XFS5 RETURNS (R VARCHAR(20) CHARACTER SET WIN1252, N INTEGER) AS BEGIN FOR SELECT C FROM XTU INTO :R DO BEGIN N = OCTET_LENGTH(R); SUSPEND; END END^
CREATE PROCEDURE XSI1 RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN SELECT UPPER(C), CHAR_LENGTH(C) FROM XTU WHERE ID = 1 INTO :R, :N; SUSPEND; END^
CREATE PROCEDURE XSI2 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (N INTEGER) AS BEGIN SELECT COUNT(*) FROM XTU WHERE C = :X INTO :N; SUSPEND; END^
CREATE PROCEDURE XSI3 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (N INTEGER) AS BEGIN SELECT COUNT(*) FROM XTU WHERE W = :X INTO :N; SUSPEND; END^
CREATE PROCEDURE XCU1 RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS DECLARE K CURSOR FOR (SELECT C FROM XTU); BEGIN OPEN K; FETCH K INTO :R; CLOSE K; N = CHAR_LENGTH(R); SUSPEND; END^
CREATE PROCEDURE XIN1 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, S VARCHAR(20) CHARACTER SET WIN1252, T VARCHAR(20), N INTEGER) AS BEGIN INSERT INTO XTT (ID, C, W, N) VALUES (1, :X, :X, :X); SELECT C, W, N, OCTET_LENGTH(N) FROM XTT WHERE ID = 1 INTO :R, :S, :T, :N; SUSPEND; END^
CREATE PROCEDURE XUP1 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN INSERT INTO XTT (ID, C) VALUES (3, 'a'); UPDATE XTT SET C = :X WHERE ID = 3; SELECT C FROM XTT WHERE ID = 3 INTO :R; SUSPEND; END^
CREATE PROCEDURE XCALLEE (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN R = UPPER(X); N = CHAR_LENGTH(X); SUSPEND; END^
CREATE PROCEDURE XCALLER (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN EXECUTE PROCEDURE XCALLEE (:X) RETURNING_VALUES :R, :N; SUSPEND; END^
CREATE PROCEDURE XCALLER2 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN SELECT R, N FROM XCALLEE(:X) INTO :R, :N; SUSPEND; END^
CREATE PROCEDURE XCALLER3 (X VARCHAR(10)) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN EXECUTE PROCEDURE XCALLEE (:X) RETURNING_VALUES :R, :N; SUSPEND; END^
CREATE PROCEDURE XPCH (X CHAR(3) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN R = X || '|'; N = OCTET_LENGTH(X); SUSPEND; END^
CREATE PROCEDURE XPCW (X CHAR(3) CHARACTER SET WIN1252) RETURNS (R VARCHAR(20) CHARACTER SET WIN1252, N INTEGER) AS BEGIN R = X || '|'; N = OCTET_LENGTH(X); SUSPEND; END^
CREATE PROCEDURE XPLV1 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS DECLARE V VARCHAR(3) CHARACTER SET UTF8; BEGIN V = X; R = V; N = CHAR_LENGTH(V); SUSPEND; END^
CREATE PROCEDURE XPLV2 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS DECLARE V VARCHAR(3); BEGIN V = X; R = V; N = CHAR_LENGTH(V); SUSPEND; END^
CREATE PROCEDURE XPLV3 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS DECLARE V VARCHAR(10) CHARACTER SET WIN1252; BEGIN V = X; R = V || V; N = OCTET_LENGTH(V || V); SUSPEND; END^
CREATE PROCEDURE XPLV4 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS DECLARE V VARCHAR(10) CHARACTER SET OCTETS; BEGIN V = X; R = V; SUSPEND; END^
CREATE PROCEDURE XPLV5 (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET ASCII) AS BEGIN R = X; SUSPEND; END^
CREATE PROCEDURE XPES (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN EXECUTE STATEMENT 'SELECT UPPER(''' || X || ''') FROM RDB$DATABASE' INTO :R; SUSPEND; END^
CREATE PROCEDURE XPCOAL (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN R = COALESCE(X, 'z'); N = CHAR_LENGTH(COALESCE(X, 'z')); SUSPEND; END^
CREATE PROCEDURE XPCASE (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = CASE WHEN X = 'a' THEN 'b' ELSE UPPER(X) END; SUSPEND; END^
CREATE PROCEDURE XPTRIM (X VARCHAR(10) CHARACTER SET UTF8) RETURNS (R VARCHAR(20) CHARACTER SET UTF8, N INTEGER) AS BEGIN R = TRIM(X); N = POSITION('b' IN X); SUSPEND; END^
CREATE FUNCTION XFL (X VARCHAR(10) CHARACTER SET UTF8) RETURNS VARCHAR(20) CHARACTER SET UTF8 AS BEGIN RETURN LPAD(X, 3, 'é'); END^
CREATE FUNCTION XFU (X VARCHAR(10) CHARACTER SET UTF8) RETURNS VARCHAR(20) CHARACTER SET UTF8 AS BEGIN RETURN UPPER(X); END^
CREATE FUNCTION XFN (X VARCHAR(10) CHARACTER SET UTF8) RETURNS INTEGER AS BEGIN RETURN CHAR_LENGTH(X); END^
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

echo "--- 6b. PROMOTED from the record: a bare local in a value the planner answers is the local"
pin  "6b an integer local times a decimal literal" "$(eb 'EXECUTE BLOCK RETURNS (R NUMERIC(10,2)) AS DECLARE X INTEGER = 3; BEGIN R = X * 1.001; SUSPEND; END')" "R|3.00"

echo "--- 7. RECORDED: still refused where the engine answers (a clean refusal, never a wrong value)"
refused "7 a local declared by a DOMAIN" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X DNUM; BEGIN X = 1.005; R = X; SUSPEND; END')" "R|1.01"
refused "7 a local declared TYPE OF COLUMN" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X TYPE OF COLUMN T2.N; BEGIN X = 1.0005; R = X; SUSPEND; END')" "R|1.001"
refused "7 DOUBLE PRECISION arithmetic on a local" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X DOUBLE PRECISION; BEGIN X = 1; R = X / 3; SUSPEND; END')" "R|0.3333333333333333"
refused "7 DECLARE ... DEFAULT a decimal" "$(eb 'EXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X NUMERIC(10,2) DEFAULT 2.345; BEGIN R = X; SUSPEND; END')" "R|2.35"
refused "7 a DOUBLE PRECISION output" "$(eb 'EXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS BEGIN R = 2.5; SUSPEND; END')" "R|2.500000000000000"

echo "--- 8a. A STORED BODY WHOSE SOURCE LOST A LITERAL IS REFUSED - the engine keeps a '?' per octet it could not transliterate"
refused $'8a LPAD with a body literal \'é\' - the stored source keeps \'??\' (it answered \'???ab\')' $'SELECT * FROM XPP(\'ab\', 5);' $'R|éééab'
refused $'8a REPLACE with a body literal \'é\' (it answered \'??b\')' $'SELECT * FROM XPS(\'ab\');' $'R|éb'
refused $'8a ...and a UTF8 argument \'é\' as well (it answered \'?Ã©\')' $'SELECT * FROM XPP(\'é\', 3);' $'R|ééé'
pin  $'8a CONTROL a genuine \'?\' literal is in the BLR as written' $'SELECT * FROM XPQ(\'ab\');' $'R|?b'
refused $'8a a stored FUNCTION whose literal was lost' $'SELECT XFL(\'ab\') FROM RDB$DATABASE;' $'XFL|éab'
echo "--- 8b. AN ARGUMENT MOVES INTO ITS PARAMETER'S CHARACTER SET, and every slot holds its value in its own set"
pin  $'8b UPPER of a UTF8 argument \'é\' (it answered \'Ã©\')' $'SELECT * FROM XPU(\'é\');' $'R|É'
pin  $'8b CONTROL UPPER of an ASCII argument' $'SELECT * FROM XPU(\'ab\');' $'R|AB'
pin  $'8b LOWER of \'ÉÈ\'' $'SELECT * FROM XPLO(\'ÉÈ\');' $'R|éè'
pin  $'8b SUBSTRING counts characters (it answered \'ãã\')' $'SELECT * FROM XPSB(\'éèàx\');' $'R|èà'
pin  $'8b X || \'-\' || X (it answered \'Ã©-Ã©\')' $'SELECT * FROM XPCT(\'é\');' $'R|é-é'
pin  $'8b CHAR_LENGTH and OCTET_LENGTH of \'éé\' (4 and 8)' $'SELECT * FROM XPLN(\'éé\');' $'N O|2 4'
refused $'8b OVERLAY over \'éèà\'' $'SELECT * FROM XPOV(\'éèà\');' $'R|éZà'
pin  $'8b RPAD pads in characters (it answered \'Ã©**\')' $'SELECT * FROM XPRP(\'é\');' $'R|é***'
pin  $'8b LPAD pads in characters' $'SELECT * FROM XPLP(\'é\');' $'R|***é'
pin  $'8b REPLACE beside a non-ASCII character' $'SELECT * FROM XPRE(\'éa\');' $'R|éb'
pin  $'8b a plain R = X (it answered \'Ã©\')' $'SELECT * FROM XPID(\'é\');' $'R|é'
pin  $'8b a WIN1252 parameter reads the octets C3 A9 as two characters' $'SELECT * FROM XPW(\'é\');' $'R N|é 2'
pin  $'8b a NONE parameter keeps the octets; UPPER cases ASCII only' $'SELECT * FROM XPN(\'é\');' $'R N|é 2'
pin  $'8b a NONE parameter into a UTF8 output' $'SELECT * FROM XPNU(\'é\');' $'R|é'
pin  $'8b a UTF8 value into a WIN1252 output (the octet E9)' $'SELECT * FROM XPUW(\'é\');' $'R|\xc9'
pin  $'8b a UTF8 \'Ω\' into a WIN1252 output is 22018 at the assignment' $'SELECT * FROM XPUW(\'Ω\');' $'R|Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets|-At procedure "PUBLIC"."XPUW" line: 1, col: 113'
pin  $'8b a UTF8 value into a NONE output' $'SELECT * FROM XPUN(\'é\');' $'R N|É 2'
pin  $'8b a WIN1252 local between UTF8 values' $'SELECT * FROM XPLV(\'é\');' $'R N|é 1'
pin  $'8b a local of the database default set (NONE)' $'SELECT * FROM XPLN2(\'é\');' $'R N|É 2'
pin  $'8b INSERT of UPPER(:X) into a UTF8 column' $'SELECT * FROM XPIN(\'é\');' $'N|1'
pin  $'8b SELECT UPPER(:X) INTO' $'SELECT * FROM XPSEL(\'é\');' $'R|É'
pin  $'8b IF (UPPER(X) = X) over a bare variable' $'SELECT * FROM XPIF(\'é\');' $'N|0'
pin  $'8b CONTROL ...an ASCII one' $'SELECT * FROM XPIF(\'E\');' $'N|1'
pin  $'8b WHILE (I < CHAR_LENGTH(X)) counts characters' $'SELECT * FROM XPWH(\'éé\');' $'N|2'
pin  $'8b an argument past its UTF8 VARCHAR(10) in characters, LOCATIONLESS (it answered)' $'SELECT * FROM XPU(\'abcdefghijk\');' $'R|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 10, actual 11'
pin  $'8b ...eleven two-octet characters' $'SELECT * FROM XPU(\'ééééééééééé\');' $'R|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 10, actual 11'
refused $'8b a stored FUNCTION over a UTF8 argument (it answered \'Ã©\')' $'SELECT XFU(\'é\') FROM RDB$DATABASE;' $'XFU|É'
refused $'8b ...and one answering a number' $'SELECT XFN(\'éé\') FROM RDB$DATABASE;' $'XFN|2'
refused $'8b a function over a UTF8 COLUMN' $'SELECT XFN(C) FROM XTU;' $'XFN|1'
echo "--- 8c. VALUES FROM AND INTO THE DATABASE, CURSORS, CALLS, LOCALS AND OUTPUTS OF EACH SET"
pin  $'8c FOR SELECT of a UTF8 column into a UTF8 output' $'SELECT * FROM XFS1;' $'R N|é 1'
pin  $'8c ...of a WIN1252 column (which holds \'Ã©\')' $'SELECT * FROM XFS2;' $'R N|Ã© 2'
pin  $'8c ...of a NONE column' $'SELECT * FROM XFS3;' $'R N|é 1'
pin  $'8c ...of a UTF8 column into a NONE output (the octets C3 A9)' $'SELECT * FROM XFS4;' $'R N|é 2'
pin  $'8c ...into a WIN1252 output' $'SELECT * FROM XFS5;' $'R N|\xe9 1'
pin  $'8c SELECT UPPER(C), CHAR_LENGTH(C) INTO' $'SELECT * FROM XSI1;' $'R N|É 1'
pin  $'8c a UTF8 variable compared with a UTF8 column' $'SELECT * FROM XSI2(\'é\');' $'N|1'
pin  $'8c ...with a WIN1252 column' $'SELECT * FROM XSI3(\'é\');' $'N|0'
pin  $'8c a cursor FETCH of a UTF8 column' $'SELECT * FROM XCU1;' $'R N|é 1'
pin  $'8c INSERT one UTF8 variable into UTF8, WIN1252 and NONE columns' $'SELECT * FROM XIN1(\'é\');' $'R S T N|é \xe9 é 2'
pin  $'8c UPDATE SET C = :X' $'SELECT * FROM XUP1(\'é\');' $'R|é'
pin  $'8c EXECUTE PROCEDURE ... RETURNING_VALUES with a UTF8 argument' $'SELECT * FROM XCALLER(\'é\');' $'R N|É 1'
refused $'8c SELECT ... FROM a procedure called with a UTF8 variable' $'SELECT * FROM XCALLER2(\'é\');' $'R N|É 1'
pin  $'8c a NONE variable into the callee\'s UTF8 parameter' $'SELECT * FROM XCALLER3(\'é\');' $'R N|É 1'
pin  $'8c EXECUTE PROCEDURE from the client' $'EXECUTE PROCEDURE XCALLEE(\'é\');' $'R N|É 1'
pin  $'8c a UTF8 CHAR(3) parameter pads in characters' $'SELECT * FROM XPCH(\'é\');' $'R N|é | 4'
pin  $'8c a WIN1252 CHAR(3) parameter' $'SELECT * FROM XPCW(\'é\');' $'R N|é | 3'
pin  $'8c \'éé\' fits a UTF8 VARCHAR(3) local' $'SELECT * FROM XPLV1(\'éé\');' $'R N|éé 2'
pin  $'8c \'éééé\' does not' $'SELECT * FROM XPLV1(\'éééé\');' $'R N|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 3, actual 4|-At procedure "PUBLIC"."XPLV1" line: 1, col: 163'
pin  $'8c \'éé\' into a NONE VARCHAR(3) local is four octets' $'SELECT * FROM XPLV2(\'éé\');' $'R N|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 3, actual 4|-At procedure "PUBLIC"."XPLV2" line: 1, col: 144'
pin  $'8c a WIN1252 local concatenated' $'SELECT * FROM XPLV3(\'é\');' $'R N|éé 2'
pin  $'8c an OCTETS local between UTF8 values' $'SELECT * FROM XPLV4(\'é\');' $'R|é'
pin  $'8c a UTF8 \'é\' into an ASCII output' $'SELECT * FROM XPLV5(\'é\');' $'R|Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets|-At procedure "PUBLIC"."XPLV5" line: 1, col: 112'
pin  $'8c CONTROL ...\'ab\' into it' $'SELECT * FROM XPLV5(\'ab\');' $'R|ab'
refused $'8c EXECUTE STATEMENT text built from a UTF8 variable' $'SELECT * FROM XPES(\'é\');' $'R|é'
pin  $'8c COALESCE over a UTF8 variable' $'SELECT * FROM XPCOAL(\'é\');' $'R N|é 1'
pin  $'8c CASE over a UTF8 variable' $'SELECT * FROM XPCASE(\'é\');' $'R|É'
pin  $'8c TRIM and POSITION over a UTF8 variable' $'SELECT * FROM XPTRIM(\' éb \');' $'R N|éb 3'
echo "--- 8d. AN EXECUTE BLOCK'S LITERALS ARE THE ATTACHMENT'S (octets under NONE)"
pin  $'8d an EXECUTE BLOCK\'s literal is the attachment\'s: \'é\' into a NONE output is two octets (it stored four)' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20), N INTEGER) AS BEGIN R = \'é\'; N = CHAR_LENGTH(R); SUSPEND; END')" $'R N|é 2'
pin  $'8d ...\'é\' || \'x\' (it answered \'Ã©x\', 5)' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20), N INTEGER) AS BEGIN R = \'é\' || \'x\'; N = OCTET_LENGTH(R); SUSPEND; END')" $'R N|éx 3'
pin  $'8d ...UPPER of it cases ASCII only' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20), N INTEGER) AS BEGIN R = UPPER(\'é\'); N = CHAR_LENGTH(R); SUSPEND; END')" $'R N|é 2'
pin  $'8d ...\'éé\' into a NONE VARCHAR(3) local (it said actual 8)' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE V VARCHAR(3); BEGIN V = \'éé\'; R = V; SUSPEND; END')" $'R|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 3, actual 4|-At block line: 1, col: 70'
refused $'8d ...REPLACE(\'abc\', \'b\', \'é\') into a UTF8 output' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = REPLACE(\'abc\', \'b\', \'é\'); SUSPEND; END')" $'R|aéc'
refused $'8d ...LPAD(\'ab\', 5, \'é\') is Malformed string into UTF8' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = LPAD(\'ab\', 5, \'é\'); SUSPEND; END')" $'R|Statement failed, SQLSTATE = 22000|Malformed string|-At block line: 1, col: 67'
refused $'8d ...a UTF8 local holding \'é\'' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20), N INTEGER) AS DECLARE V VARCHAR(10) CHARACTER SET UTF8 = \'é\'; BEGIN R = UPPER(V); N = OCTET_LENGTH(R); SUSPEND; END')" $'R N|É 2'
refused $'8d OVERLAY with FROM (it was -204 Table unknown "2")' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = OVERLAY(\'abc\' PLACING \'x\' FROM 2 FOR 1); SUSPEND; END')" $'R|axc'
refused $'8d ...and the same under a UTF8 output' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = OVERLAY(\'abc\' PLACING \'é\' FROM 2 FOR 1); SUSPEND; END')" $'R|aéc'
refused $'8d SUBSTRING of a NONE literal cuts octets: Malformed string into UTF8' "$(eb $'EXECUTE BLOCK RETURNS (R VARCHAR(20) CHARACTER SET UTF8) AS BEGIN R = SUBSTRING(\'éèà\' FROM 2 FOR 1); SUSPEND; END')" $'R|Statement failed, SQLSTATE = 22000|Malformed string|-At block line: 1, col: 67'
echo "--- 8e. A NONE LITERAL CONCATENATED WITH A UTF8 OPERAND IS READ AS UTF8 (the planner a typed variable reaches)"
pin  $'8e a UTF8 column || a NONE literal reads the literal\'s octets as UTF8 (it answered \'éÃ©\')' $'SELECT C || \'é\', \'é\' || C FROM XTU;' $'CONCATENATION CONCATENATION|éé éé'
dsame $'8e ...and its describe did not move' $'SELECT C || \'é\', \'é\' || C FROM XTU;'
pin  $'8e ...its lengths (3 and 6)' $'SELECT CHAR_LENGTH(C || \'é\'), OCTET_LENGTH(C || \'é\'), CHAR_LENGTH(\'é\' || C) FROM XTU;' $'CHAR_LENGTH OCTET_LENGTH CHAR_LENGTH|2 4 2'
pin  $'8e ...a UTF8 CAST || a NONE literal' $'SELECT CAST(x\'C3A9\' AS VARCHAR(10) CHARACTER SET UTF8) || \'é\' FROM RDB$DATABASE;' $'CONCATENATION|éé'
pin  $'8e CONTROL a WIN1252 column || the literal' $'SELECT OCTET_LENGTH(W || \'é\'), CHAR_LENGTH(W || \'é\') FROM XTU;' $'OCTET_LENGTH CHAR_LENGTH|4 4'
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-psqlassign-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 135 ]; then echo "FAIL only $ran checks ran (floor 135)"; fail=1; fi
exit $fail
