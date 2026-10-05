#!/bin/bash
# A ROUTINE'S TEXT PARAMETER IN A UTF8 DATABASE - a procedure, a function,
# a package member made by THIS server, read by the engine.
#
# The engine's DSQL types an unqualified CHAR / VARCHAR parameter in the
# DATABASE'S DEFAULT SET: in a UTF8 database `X VARCHAR(5)` is a domain of
# set 4, 20 bytes, character length 5, and the routine's BLR descriptors
# say blr_varying2 4 / 20. This server wrote set 0 over 5 bytes and
# compiled set 0 descriptors - its own reading was consistent, but the
# ENGINE, running the routine, refused a 'héllo' argument as *string right
# truncation* (expected length 5, actual 6) and described the outputs as
# NONE. Measured on 6.0.0.2196 against an engine-created twin.
#
# Every cell has both servers create the same routines, then the ENGINE
# reads both files: the parameter domains, the describe, a non-ASCII call.
# A string literal in the routine's BLR carries the ATTACHMENT's set on the
# engine (0150F04000 under UTF8, 0150F00000 under NONE), and so here now:
# every routine's BLR is the engine's byte for byte.
#
#   qa/serve-real-utf8routines.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4651}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
gone() { sudo -n rm -f "$1" 2>/dev/null; rm -f "$1" 2>/dev/null; }
mk() { # <file> <default set>: an engine-made fixture
    gone "$1"
    printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET %s;
CREATE TABLE T (ID INT, S VARCHAR(10));
INSERT INTO T VALUES (1, 'café');
COMMIT;\n" "$REAL" "$1" "$U" "$P" "$2" | "$ISQL" -q -ch UTF8 > /tmp/u8r-build.log 2>&1
    [ -s "$1" ] || { echo "FAIL fixture $1 not created"; sed 's/^/   /' /tmp/u8r-build.log; exit 1; }
    sudo -n chmod 666 "$1" 2>/dev/null
}
E8="$D/u8r-e8-$PORT.fdb"; F8="$D/u8r-f8-$PORT.fdb"; EN="$D/u8r-en-$PORT.fdb"; FN="$D/u8r-fn-$PORT.fdb"
mk "$E8" UTF8; mk "$F8" UTF8; mk "$EN" NONE; mk "$FN" NONE
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-u8r-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; for f in "$E8" "$F8" "$EN" "$FN"; do gone "$f"; done' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -ch "${3:-UTF8}" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ -z "$2" ]; then echo "FAIL $1 [the engine answered nothing]"; fail=1
    elif [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}
MAKE="SET TERM ^;
CREATE PROCEDURE PV (X VARCHAR(5), C CHAR(2)) RETURNS (R VARCHAR(10), Q CHAR(4)) AS BEGIN R = X || '!'; Q = C; SUSPEND; END^
CREATE FUNCTION FV (X CHAR(3)) RETURNS VARCHAR(8) AS BEGIN RETURN X || '?'; END^
CREATE PROCEDURE PD (X DECFLOAT(16)) RETURNS (R DECFLOAT(34), S DECFLOAT) AS BEGIN R = X * 2; S = CAST(X AS DECFLOAT(34)); SUSPEND; END^
CREATE FUNCTION FD (X DECFLOAT(34)) RETURNS DECFLOAT(16) AS BEGIN RETURN X / 4; END^
CREATE PROCEDURE PF RETURNS (R INT) AS DECLARE C CURSOR FOR (SELECT ID FROM T FOR UPDATE OF S); BEGIN OPEN C; FETCH C INTO R; CLOSE C; SUSPEND; END^
CREATE PACKAGE PK AS BEGIN PROCEDURE PP (X VARCHAR(4)) RETURNS (R VARCHAR(6)); FUNCTION PF (X VARCHAR(3)) RETURNS VARCHAR(5); END^
CREATE PACKAGE BODY PK AS BEGIN PROCEDURE PP (X VARCHAR(4)) RETURNS (R VARCHAR(6)) AS BEGIN R = X || '#'; SUSPEND; END FUNCTION PF (X VARCHAR(3)) RETURNS VARCHAR(5) AS BEGIN RETURN X || '%'; END END^
SET TERM ;^
COMMIT;"
CAT="SELECT PP.RDB\$PROCEDURE_NAME, PP.RDB\$PARAMETER_NAME, F.RDB\$FIELD_TYPE, F.RDB\$FIELD_LENGTH, F.RDB\$CHARACTER_LENGTH, F.RDB\$CHARACTER_SET_ID FROM RDB\$PROCEDURE_PARAMETERS PP JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = PP.RDB\$FIELD_SOURCE WHERE PP.RDB\$SYSTEM_FLAG = 0 ORDER BY 1, 2;
SELECT FA.RDB\$FUNCTION_NAME, FA.RDB\$ARGUMENT_POSITION, F.RDB\$FIELD_TYPE, F.RDB\$FIELD_LENGTH, F.RDB\$CHARACTER_LENGTH, F.RDB\$CHARACTER_SET_ID FROM RDB\$FUNCTION_ARGUMENTS FA JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = FA.RDB\$FIELD_SOURCE WHERE FA.RDB\$SYSTEM_FLAG = 0 ORDER BY 1, 2;"
CALL="SET SQLDA_DISPLAY ON;
SELECT * FROM PV('héllo', 'é');
SELECT FV('é') FROM RDB\$DATABASE;
SET SQLDA_DISPLAY OFF;
SELECT * FROM PK.PP('ñaño');
SELECT PK.PF('ü') FROM RDB\$DATABASE;
SELECT * FROM PV('héllos', 'x');
SELECT * FROM PD(1.25); SELECT FD(10) FROM RDB\$DATABASE; SELECT * FROM PF;"

for pair in "UTF8:$E8:$F8" "NONE:$EN:$FN"; do
    IFS=: read cs e f <<<"$pair"
    echo "--- a $cs database"
    check "$cs: the create, each server on its own file" "$(run "127.0.0.1/$REAL:$e" "$MAKE")" "$(run "127.0.0.1/$PORT:$f" "$MAKE")"
    check "$cs: the engine reads this server's parameter domains as its own" "$(run "127.0.0.1/$REAL:$e" "$CAT")" "$(run "127.0.0.1/$REAL:$f" "$CAT")"
    check "$cs: the engine CALLS this server's routines (describe, non-ASCII, a too-long argument)" "$(run "127.0.0.1/$REAL:$e" "$CALL")" "$(run "127.0.0.1/$REAL:$f" "$CALL")"
    check "$cs: ...and so does this server" "$(run "127.0.0.1/$REAL:$e" "$CALL")" "$(run "127.0.0.1/$PORT:$f" "$CALL")"
    check "$cs: ...under a NONE attachment too" "$(run "127.0.0.1/$REAL:$e" "SELECT R, Q FROM PV('abc', 'z'); SELECT FV('x') FROM RDB\$DATABASE;" NONE)" "$(run "127.0.0.1/$PORT:$f" "SELECT R, Q FROM PV('abc', 'z'); SELECT FV('x') FROM RDB\$DATABASE;" NONE)"
done

echo "--- the BLR itself"
BLR="SELECT RDB\$PROCEDURE_NAME, HEX_ENCODE(CAST(RDB\$PROCEDURE_BLR AS VARCHAR(4000) CHARACTER SET OCTETS)) FROM RDB\$PROCEDURES WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;
SELECT RDB\$FUNCTION_NAME, HEX_ENCODE(CAST(RDB\$FUNCTION_BLR AS VARCHAR(4000) CHARACTER SET OCTETS)) FROM RDB\$FUNCTIONS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;"
check "every routine's BLR is the engine's byte for byte - descriptors in the database's set, literals in the attachment's (promoted)" "$(run "127.0.0.1/$REAL:$E8" "$BLR")" "$(run "127.0.0.1/$REAL:$F8" "$BLR")"
check "...in a NONE database" "$(run "127.0.0.1/$REAL:$EN" "$BLR")" "$(run "127.0.0.1/$REAL:$FN" "$BLR")"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-u8r-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 13 ]; then echo "FAIL only $ran checks ran (floor 13) - cells went missing"; fail=1; fi
exit $fail
