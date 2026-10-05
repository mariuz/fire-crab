#!/bin/bash
# AN EXPRESSION OVER A SELECTABLE PROCEDURE'S OUTPUTS, with no clause:
# `SELECT CHAR_LENGTH(R), K * 2 FROM P` was REFUSED here - the projection
# picker for a bare call takes only plain output columns - while the same
# projection under a WHERE (routed to the bound row source) answered. Any
# non-column item now takes the bound route. Measured on 6.0.0.2196.
#
# RECORDED: a `?` in the projection and an undefined alias refuse with
# the generic vector here, -804 / -206 on the engine (as before).
#
#   qa/serve-real-procexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-6190}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/pex-eng-$PORT.fdb"; FC="$D/pex-fc-$PORT.fdb"
LOG="/tmp/fc-serve-pex-$PORT.log"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
SET TERM ^;
CREATE PROCEDURE GEN (N INT) RETURNS (K INT, S VARCHAR(12)) AS BEGIN K = 0; WHILE (K < N) DO BEGIN K = K + 1; S = 'v' || K; SUSPEND; END END^
CREATE PROCEDURE P2 RETURNS (R VARCHAR(10), K INT) AS BEGIN R = 'abc'; K = 1; SUSPEND; R = 'xyz'; K = 2; SUSPEND; END^
SET TERM ;^
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/pex-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/pex-build.log; exit 1; }
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
# both <label> <sql> <a fragment the engine's answer must hold>
both() {
    ran=$((ran + 1))
    local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    case "$e" in *"$3"*) ;; *) echo "FAIL $1 - THE ENGINE ANSWERS [$e], without [$3]"; fail=1; return;; esac
    if [ "$c" != "$e" ]; then echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1
    else echo "OK   $1"; fi
}
both "functions and arithmetic over a parameterless call" "SELECT CHAR_LENGTH(R), UPPER(R), K * 2 FROM P2;" "|3 XYZ 4|"
both "aliases and a concatenation" "SELECT K + 1 AS NK, S || '!' FROM GEN(3);" "|4 v3!|"
both "a qualified column under the call's alias" "SELECT G.K * 10, G.S FROM GEN(2) G;" "|20 v2|"
both "the procedure's own name as qualifier" "SELECT GEN.K + 0 FROM GEN(2);" "|2|"
both "CAST and COALESCE" "SELECT CAST(K AS VARCHAR(5)) || S, COALESCE(S, 'n') FROM GEN(2);" "2v2"
both "a scalar subselect beside an output" "SELECT K, (SELECT COUNT(*) FROM RDB\$DATABASE) FROM GEN(2);" "|2 1|"
both "IIF" "SELECT IIF(K > 1, 'big', 'small') FROM GEN(3);" "|big|"
both "a literal beside an output" "SELECT 1, K FROM GEN(2);" "|1 2|"
both "SUBSTRING" "SELECT SUBSTRING(S FROM 1 FOR 1), K FROM GEN(1);" "|v 1|"
both "an empty call" "SELECT K + 0 FROM GEN(0);" "X|"
both "* beside an output is a syntax error on both" "SELECT *, K FROM GEN(1);" "Token unknown"
both "the describe" "SET SQLDA_DISPLAY ON; SELECT K * 2, S || 'x' FROM GEN(1);" "sqltype"
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "$LOG"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 13 ]; then echo "FAIL only $ran checks ran (floor 13) - cells went missing"; fail=1; fi
exit $fail
