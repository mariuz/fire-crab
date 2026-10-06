#!/bin/bash
# A SESSION CONTEXT WORD IN A ROUTINE OR VIEW THIS SERVER COMPILES. dsql read
# a bare CURRENT_USER / USER / CURRENT_ROLE as a COLUMN and stored
# `blr_field 'CURRENT_ROLE'`: a view over `"CURRENT_ROLE" = CURRENT_ROLE`
# compared the column with itself and answered every row, a procedure the
# same, and a view over `S = CURRENT_USER` failed at use ("column
# CURRENT_USER is not defined"). The engine stores blr_user_name (0x2C) and
# blr_current_role (0xAE). A DELIMITED name spelling a context word is a
# column the token stream cannot tell from the keyword: refused.
#
# Every cell has both servers create the same objects, then the ENGINE reads
# both files: the stored BLR byte for byte, and the answers.
#
#   qa/serve-real-ctxwords.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-6250}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/ctxw-eng-$PORT.fdb"; FC="$D/ctxw-fc-$PORT.fdb"
LOG="/tmp/fc-serve-ctxw-$PORT.log"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE Q (ID INT, \"CURRENT_ROLE\" VARCHAR(10), S VARCHAR(10));
INSERT INTO Q VALUES (1, 'r', 'SYSDBA'); INSERT INTO Q VALUES (2, 'NONE', 'x');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/ctxw-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/ctxw-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "$LOG" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }
fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/^ *//; s/ *$//' | tr '\n' '|'; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fc:     $3"; fail=1; fi; }
MAKE="CREATE VIEW V2 AS SELECT ID FROM Q WHERE S = CURRENT_USER;
CREATE VIEW V4 AS SELECT ID FROM Q WHERE S = USER OR CURRENT_ROLE = 'NONE';
SET TERM ^;
CREATE PROCEDURE PR RETURNS (N INT) AS BEGIN FOR SELECT ID FROM Q WHERE S = CURRENT_USER OR CURRENT_ROLE = 'NONE' INTO :N DO SUSPEND; END^
CREATE PROCEDURE PU RETURNS (N INT) AS BEGIN FOR SELECT ID FROM Q WHERE ID = 1 AND S = USER INTO :N DO SUSPEND; END^
SET TERM ;^
COMMIT;"
check "the create, each server on its own file" "$(run "127.0.0.1/$REAL:$ENG" "$MAKE")" "$(run "127.0.0.1/$PORT:$FC" "$MAKE")"
BLR="SELECT RDB\$RELATION_NAME, HEX_ENCODE(CAST(RDB\$VIEW_BLR AS VARCHAR(2000) CHARACTER SET OCTETS)) FROM RDB\$RELATIONS WHERE RDB\$VIEW_BLR IS NOT NULL AND RDB\$SYSTEM_FLAG = 0 ORDER BY 1;
SELECT RDB\$PROCEDURE_NAME, HEX_ENCODE(CAST(RDB\$PROCEDURE_BLR AS VARCHAR(2000) CHARACTER SET OCTETS)) FROM RDB\$PROCEDURES WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;"
check "the stored BLR is the engine's byte for byte (blr_user_name 2C, blr_current_role AE)" "$(run "127.0.0.1/$REAL:$ENG" "$BLR")" "$(run "127.0.0.1/$REAL:$FC" "$BLR")"
USE="SELECT * FROM V2; SELECT * FROM V4; SELECT * FROM PR; SELECT * FROM PU;"
check "the engine runs this server's objects as its own" "$(run "127.0.0.1/$REAL:$ENG" "$USE")" "$(run "127.0.0.1/$REAL:$FC" "$USE")"
check "...and so does this server" "$(run "127.0.0.1/$REAL:$ENG" "$USE")" "$(run "127.0.0.1/$PORT:$FC" "$USE")"
# a delimited "CURRENT_ROLE" beside the keyword: the engine compares the
# column with the session role; this server refuses rather than store the
# column twice (it answered both rows)
ran=$((ran + 1))
e=$(run "127.0.0.1/$REAL:$ENG" "CREATE VIEW V1 AS SELECT ID FROM Q WHERE \"CURRENT_ROLE\" = CURRENT_ROLE; COMMIT; SELECT * FROM V1;")
c=$(run "127.0.0.1/$PORT:$FC" "CREATE VIEW V1 AS SELECT ID FROM Q WHERE \"CURRENT_ROLE\" = CURRENT_ROLE; COMMIT; SELECT * FROM V1;")
case "$e|$c" in
    *"|ID|"*"|1|"*"|2|"*) echo "FAIL a delimited context word beside the keyword: this server answers both rows again [$c]"; fail=1;;
    "ID|============|2|"*"|Statement failed"*) echo "OK   a delimited context word beside the keyword: refused (the engine answers row 2)";;
    *) echo "FAIL a delimited context word beside the keyword: engine [$e] fc [$c]"; fail=1;;
esac
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "$LOG"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 6 ]; then echo "FAIL only $ran checks ran (floor 6) - cells went missing"; fail=1; fi
exit $fail
