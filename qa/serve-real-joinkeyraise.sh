#!/bin/bash
# A JOIN INNER'S INDEX KEY IS BUILT WHEN THE INNER OPENS - so a literal the
# keyed column cannot take raises 22018 there, before any row, over an
# EMPTY inner. fire-crab had this law for ONE table's WHERE only
# (`Predicate::key_conversion`); over an empty indexed `E(N INT)` it
# answered T's rows (LEFT) or none (INNER) where the engine raises, and a
# COUNT(*) over the join was counted at PREPARE, where the raise refused
# the statement. Found under the exe switch (slice 3), measured on 2196:
#
# - the inner opens PER OUTER ROW that passes the outer-only conjuncts of
#   the WHERE and of the ON: an EMPTY outer, or one filtered to nothing
#   first, answers;
# - a WHERE comparison on the inner keys it too - it rejects the NULL
#   padding, so a LEFT join runs as an inner one - while `IS NULL OR ..`
#   does not, and an UNINDEXED inner never raises;
# - a RIGHT / FULL join's preserved side drives: the LEFT relation opens
#   per right row;
# - the key laws are the single table's: `<>` keys nothing, an OR whose
#   other branch is unkeyed keys nothing, the last writer of a bound wins.
#
# RECORDED, not fixed: the engine STREAMS an outer row the gates turned
# away before the raise (row 1, then 22018) where this server raises
# first; and a SUBQUERY's inner key (EXISTS / IN / a scalar subselect over
# the indexed E) - the subquery fold has no error channel yet.
#
#   qa/serve-real-joinkeyraise.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-6070}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/jkr-eng-$PORT.fdb"; FC="$D/jkr-fc-$PORT.fdb"
LOG="/tmp/fc-serve-jkr-$PORT.log"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INT); INSERT INTO T VALUES (1); INSERT INTO T VALUES (2);
CREATE TABLE E (ID INT, N INT); CREATE INDEX E_N ON E (N);
CREATE TABLE E2 (ID INT, N INT);
CREATE TABLE Z (ID INT);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/jkr-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/jkr-build.log; exit 1; }
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
# a sentinel row after every statement, so an answer that is NOTHING is
# still an answer and a dead connection is not
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/^ *//; s/ *$//' | tr '\n' '|'; }
# both <label> <sql> <want>: the engine must answer <want> (pinned, so a
# cell that measures nothing cannot pass) and this server the same
both() {
    ran=$((ran + 1))
    local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" != "$e" ]; then echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1
    else echo "OK   $1"; fi
}
# rec <label> <sql> <engine> <this server>: a recorded divergence
rec() {
    ran=$((ran + 1))
    local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}
R='Statement failed, SQLSTATE = 22018|conversion error from string "x"|'
RAISE="ID|============|${R}X|======|DONE|"
ROWS='ID|============|1|2|X|======|DONE|'
NONE='X|======|DONE|'

echo "--- 1 the inner opens per outer row, and its key raises"
both "1 LEFT JOIN, ON E.ID = T.ID AND E.N = 'x'" "SELECT T.ID FROM T LEFT JOIN E ON E.ID = T.ID AND E.N = 'x';" "$RAISE"
both "1 LEFT JOIN, ON E.N = 'x' alone" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x';" "$RAISE"
both "1 INNER JOIN" "SELECT T.ID FROM T JOIN E ON E.N = 'x';" "$RAISE"
both "1 a range: ON E.N > 'x'" "SELECT T.ID FROM T LEFT JOIN E ON E.N > 'x';" "$RAISE"
both "1 BETWEEN: the upper bound is built first" "SELECT T.ID FROM T LEFT JOIN E ON E.N BETWEEN 'x' AND 'y';" "ID|============|Statement failed, SQLSTATE = 22018|conversion error from string \"y\"|X|======|DONE|"
both "1 IN ('x')" "SELECT T.ID FROM T LEFT JOIN E ON E.N IN ('x');" "$RAISE"
both "1 the STRICT grammar: '1 2'" "SELECT T.ID FROM T LEFT JOIN E ON E.N = '1 2';" "ID|============|Statement failed, SQLSTATE = 22018|conversion error from string \"1 2\"|X|======|DONE|"
both "1 under ORDER BY" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' ORDER BY T.ID DESC;" "$RAISE"
both "1 under FIRST 1" "SELECT FIRST 1 T.ID FROM T LEFT JOIN E ON E.N = 'x';" "$RAISE"
both "1 COUNT(*) raises at EXECUTE (it was counted at prepare and refused)" "SELECT COUNT(*) FROM T LEFT JOIN E ON E.N = 'x';" "COUNT|=====================|${R}X|======|DONE|"
both "1 the second step of a chain" "SELECT T.ID FROM T LEFT JOIN E2 ON E2.ID = T.ID LEFT JOIN E ON E.N = 'x';" "$RAISE"
both "1 the first step of a chain" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' LEFT JOIN E2 ON E2.ID = T.ID;" "$RAISE"
both "1 after an inner self-join" "SELECT T.ID FROM T JOIN T T2 ON T2.ID = T.ID LEFT JOIN E ON E.N = 'x';" "$RAISE"
both "1 a WHERE the padding passes" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' WHERE E.ID IS NULL;" "$RAISE"

echo "--- 2 what reaches the open: the outer-only gates"
both "2 an EMPTY outer never opens the inner (LEFT)" "SELECT Z.ID FROM Z LEFT JOIN E ON E.N = 'x';" "$NONE"
both "2 ...nor INNER" "SELECT Z.ID FROM Z JOIN E ON E.N = 'x';" "$NONE"
both "2 WHERE 1 = 0" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' WHERE 1 = 0;" "$NONE"
both "2 a WHERE on the outer turning every row away (INNER)" "SELECT T.ID FROM T JOIN E ON E.ID = T.ID AND E.N = 'x' WHERE T.ID = 5;" "$NONE"
both "2 ...(LEFT)" "SELECT T.ID FROM T LEFT JOIN E ON E.ID = T.ID AND E.N = 'x' WHERE T.ID = 5;" "$NONE"
both "2 an outer-only ON conjunct turning every row away (INNER)" "SELECT T.ID FROM T JOIN E ON T.ID = 5 AND E.N = 'x';" "$NONE"
both "2 ...(LEFT: every row padded, nothing raised)" "SELECT T.ID FROM T LEFT JOIN E ON T.ID = 5 AND E.N = 'x';" "$ROWS"
both "2 an outer-only ON EXPRESSION passing row 1" "SELECT T.ID FROM T LEFT JOIN E ON T.ID + 0 = 1 AND E.N = 'x';" "$RAISE"
both "2 a WHERE passing row 1" "SELECT T.ID FROM T LEFT JOIN E ON T.ID = E.ID AND E.N = 'x' WHERE T.ID = 1;" "$RAISE"
both "2 ...with the ON's literal alone" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' WHERE T.ID = 1;" "$RAISE"
rec "2 RECORDED the engine STREAMS the turned-away row 1 before row 2 raises" "SELECT T.ID FROM T LEFT JOIN E ON T.ID = 2 AND E.N = 'x';" "ID|============|1|${R}X|======|DONE|" "$RAISE"

echo "--- 3 a WHERE comparison on the inner keys it (the LEFT runs as an INNER)"
both "3 LEFT .. WHERE E.N = 'x'" "SELECT T.ID FROM T LEFT JOIN E ON E.ID = T.ID WHERE E.N = 'x';" "$RAISE"
both "3 INNER .. WHERE E.N = 'x'" "SELECT T.ID FROM T JOIN E ON E.ID = T.ID WHERE E.N = 'x';" "$RAISE"
both "3 IS NULL OR .. is not null-rejecting: it answers" "SELECT T.ID FROM T LEFT JOIN E ON E.ID = T.ID WHERE E.N IS NULL OR E.N = 'x';" "$ROWS"
both "3 an outer conjunct beside it turns every row away" "SELECT T.ID FROM T LEFT JOIN E ON E.ID = T.ID WHERE T.ID = 5 AND E.N = 'x';" "$NONE"
both "3 an UNINDEXED inner: none, no raise" "SELECT T.ID FROM T LEFT JOIN E2 ON E2.ID = T.ID WHERE E2.N = 'x';" "$NONE"

echo "--- 4 RIGHT and FULL: the preserved side drives, the left relation opens"
both "4 E RIGHT JOIN T" "SELECT T.ID FROM E RIGHT JOIN T ON E.N = 'x';" "$RAISE"
both "4 ...a right-only ON conjunct turning every row away" "SELECT T.ID FROM E RIGHT JOIN T ON E.N = 'x' AND T.ID = 5;" "$ROWS"
both "4 ...a WHERE on the right turning every row away" "SELECT T.ID FROM E RIGHT JOIN T ON E.N = 'x' WHERE T.ID = 5;" "$NONE"
both "4 E FULL JOIN T" "SELECT T.ID FROM E FULL JOIN T ON E.N = 'x';" "$RAISE"
both "4 T FULL JOIN E" "SELECT T.ID FROM T FULL JOIN E ON E.N = 'x';" "$RAISE"

echo "--- 5 the key laws are the single table's (controls)"
both "5 <> keys nothing" "SELECT T.ID FROM T LEFT JOIN E ON E.N <> 'x';" "$ROWS"
both "5 an OR whose other branch is unkeyed keys nothing" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' OR E.ID = 1;" "$ROWS"
both "5 ...INNER, the OR over a gated branch" "SELECT T.ID FROM T JOIN E ON T.ID = 5 AND E.N = 'x' OR E.ID = 1;" "$NONE"
both "5 the LAST writer of a bound wins: E.N = 'x' AND E.N = 5" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 'x' AND E.N = 5;" "$ROWS"
both "5 ...E.N = 5 AND E.N = 'x' raises" "SELECT T.ID FROM T LEFT JOIN E ON E.N = 5 AND E.N = 'x';" "$RAISE"
both "5 an UNINDEXED inner answers (LEFT)" "SELECT T.ID FROM T LEFT JOIN E2 ON E2.N = 'x';" "$ROWS"
both "5 ...(INNER)" "SELECT T.ID FROM T JOIN E2 ON E2.N = 'x';" "$NONE"
both "5 inside an EXISTS body's join" "SELECT T.ID FROM T WHERE T.ID = 1 AND EXISTS (SELECT 1 FROM T T2 LEFT JOIN E ON E.N = 'x');" "$RAISE"

echo "--- 6 RECORDED: a SUBQUERY's inner key (the fold has no error channel)"
rec "6 RECORDED uncorrelated EXISTS" "SELECT T.ID FROM T WHERE EXISTS (SELECT 1 FROM E WHERE E.N = 'x');" "$RAISE" "$NONE"
rec "6 RECORDED IN (SELECT ..)" "SELECT T.ID FROM T WHERE T.ID IN (SELECT E.ID FROM E WHERE E.N = 'x');" "$RAISE" "$NONE"
rec "6 RECORDED a scalar subselect" "SELECT (SELECT COUNT(*) FROM E WHERE E.N = 'x') FROM T;" "COUNT|=====================|${R}X|======|DONE|" "COUNT|=====================|0|0|X|======|DONE|"
rec "6 RECORDED an uncorrelated EXISTS is an INVARIANT: it raises over an empty outer" "SELECT Z.ID FROM Z WHERE EXISTS (SELECT 1 FROM E WHERE E.N = 'x');" "$RAISE" "$NONE"
rec "6 RECORDED correlated EXISTS" "SELECT T.ID FROM T WHERE EXISTS (SELECT 1 FROM E WHERE E.ID = T.ID AND E.N = 'x');" "$RAISE" "$NONE"
both "6 control: a scalar subselect over an empty outer is never evaluated" "SELECT (SELECT COUNT(*) FROM E WHERE E.N = 'x') FROM Z;" "$NONE"
both "6 control: an unindexed EXISTS body answers" "SELECT T.ID FROM T WHERE EXISTS (SELECT 1 FROM E2 WHERE E2.N = 'x');" "$NONE"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "$LOG"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 51 ]; then echo "FAIL only $ran checks ran (floor 51) - cells went missing"; fail=1; fi
exit $fail
