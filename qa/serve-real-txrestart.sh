#!/bin/bash
# THE TRANSACTION AFTER A DSQL COMMIT / ROLLBACK.
#
# isql opens its user transaction with the STATEMENT `SET TRANSACTION`
# (KeepTranParams - a SNAPSHOT unless the last SET TRANSACTION said
# otherwise) and ends it with the statement `COMMIT`. The engine answers
# that COMMIT with transaction object 0; the client drops its transaction
# on a 0 (client/interface.cpp:3802) and isql opens the next one the same
# way. This server echoed the old handle: isql went on using a handle
# whose transaction had ended, and it was served READ COMMITTED - a SELECT
# after `COMMIT` saw another attachment's LATER commit (measured on 2196:
# the engine counts 1 row and reports MON$ISOLATION_MODE 1, concurrency;
# this server counted 2). Every isql script reading after a COMMIT ran
# read-committed here. RETAIN keeps the transaction - and its object.
#
# Each cell: session A runs its first part, session B commits an INSERT,
# session A runs its second part; the two outputs are compared whole.
#
#   qa/serve-real-txrestart.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4601}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/txrestart-eng.fdb"; FC="$D/txrestart-fc.fdb"
FIFO="$D/txrestart-$PORT.fifo"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-txrestart-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC" "$FIFO"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
fresh() {
    rm -f "$ENG" "$FC"
    printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INTEGER);
INSERT INTO T VALUES (1);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/txrestart-build.log 2>&1
    [ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/txrestart-build.log; exit 1; }
    cp "$ENG" "$FC"; chmod 666 "$FC"
}
# two sessions on one database: A's first part, B's script, A's second
two() { # <db url> <A1> <B> <A2>
    rm -f "$FIFO"; mkfifo "$FIFO"
    ( timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" < "$FIFO" 2>&1 | sed 's/  */ /g; s/ *$//' | grep -v '^$' | tr '\n' '|'; echo ) &
    local reader=$!
    exec 7>"$FIFO"
    echo "$2" >&7
    sleep 1
    printf '%s\n' "$3" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" > /dev/null 2>&1
    sleep 1
    echo "$4" >&7
    exec 7>&-
    wait $reader
}
cell() { # <label> <A1> <B> <A2>
    ran=$((ran + 1))
    fresh
    local e c
    e=$(two "127.0.0.1/$REAL:$ENG" "$2" "$3" "$4"); c=$(two "127.0.0.1/$PORT:$FC" "$2" "$3" "$4")
    if [ "${e#*A}" = "$e" ]; then echo "FAIL $1 [the engine printed nothing]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
B="INSERT INTO T VALUES (99); COMMIT;"

echo "--- 1 after COMMIT / ROLLBACK: a fresh SNAPSHOT, opened before B's commit"
cell "1 COMMIT, then a read across B's commit"   "SELECT COUNT(*) AS A0 FROM T; COMMIT; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; SELECT MAX(ID) AS A2M FROM T; COMMIT; SELECT COUNT(*) AS A3 FROM T;"
cell "1 ROLLBACK, then the same"                  "SELECT COUNT(*) AS A0 FROM T; ROLLBACK; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"
cell "1 a DML transaction committed, then read"   "INSERT INTO T VALUES (2); COMMIT; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; UPDATE T SET ID = ID; COMMIT;"
cell "1 two COMMITs before B"                      "COMMIT; COMMIT; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"
echo "--- 2 RETAIN keeps the transaction and its snapshot"
cell "2 COMMIT RETAIN"                             "SELECT COUNT(*) AS A0 FROM T; COMMIT RETAIN; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"
cell "2 ROLLBACK RETAIN"                           "SELECT COUNT(*) AS A0 FROM T; ROLLBACK RETAIN; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"
echo "--- 3 the next transaction keeps the LAST SET TRANSACTION's words"
cell "3 SET TRANSACTION READ COMMITTED, COMMIT, read" "SET TRANSACTION READ COMMITTED; SELECT COUNT(*) AS A0 FROM T; COMMIT; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"
cell "3 ...and SNAPSHOT again"                     "SET TRANSACTION READ COMMITTED; COMMIT; SET TRANSACTION SNAPSHOT; COMMIT; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"
echo "--- 4 CONTROLS"
cell "4 no COMMIT at all: the first transaction's snapshot" "SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT; SELECT COUNT(*) AS A3 FROM T;"
cell "4 an explicit READ COMMITTED sees B"         "COMMIT; SET TRANSACTION READ COMMITTED; SELECT COUNT(*) AS A1 FROM T;" "$B" "SELECT COUNT(*) AS A2 FROM T; COMMIT;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-txrestart-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 11 ]; then echo "FAIL only $ran checks ran (floor 11) - cells went missing"; fail=1; fi
exit $fail
