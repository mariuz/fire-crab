#!/bin/bash
# A DEEP EXPRESSION MUST NOT TAKE THE SERVER DOWN.
#
# Planning is recursive descent over a parsed expression, so a long chain
# of binary operators costs stack in proportion to its length. On the
# default 2 MiB thread stack, ~1000 chained `||` overflowed it - and a
# Rust stack overflow ABORTS THE PROCESS. Measured before the fix:
#
#     thread '<unknown>' has overflowed its stack
#     fatal runtime error: stack overflow, aborting
#
# One client statement killed the whole server. An idle SECOND connection,
# healthy beforehand, then hung until its timeout - so this was not a
# per-connection failure but a denial of service reachable by any client
# that can send a SELECT. It outranks every wrong answer in this suite.
#
# The cure has two halves and needs both. Connection threads now get a
# 16 MiB stack, which raises the ceiling far enough to ANSWER the depths
# the engine answers; and `stmt_too_deep` refuses past a bound well under
# what that survives, because NO stack size makes unbounded recursion
# safe - the next report would just need a longer statement.
#
# WHAT THIS GATE ASSERTS, and why it is unlike the others here: not that
# two servers agree, but that fire-crab SURVIVES. Every check runs a deep
# statement and then asks a SECOND, independent connection whether the
# server is still there. A gate that only compared answers would score a
# dead server as "both returned nothing".
#
#   qa/serve-real-deepexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4776}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-deep-a.fdb"; B="$D/fc-deep-b.fdb"
fail=0; ran=0
mkdir -p "$D"
Q=/tmp/fc-deep-$$.sql

mkdb() { rm -f "${1#*:}"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER, S VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1,'a'); INSERT INTO T VALUES (2,'b'); INSERT INTO T VALUES (3,'c');
COMMIT;
EOF
}
mkdb "$A"; mkdb "127.0.0.1/$REAL:$B"
chmod 666 "$A" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-deep-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$Q"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

chain() { # <op> <n> <term>  -> the expression text
    python3 -c "import sys; print(sys.argv[1].join([sys.argv[3]]*int(sys.argv[2])))" "$2" "$3" "$4"
}
# the LIVENESS check: a second, independent connection after the deep one
alive() {
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
        timeout 30 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | tr -dc '0-9'
}
survives() { # <label> <sql>
    ran=$((ran + 1))
    printf 'SET HEADING OFF;\n%s;\n' "$2" > "$Q"
    timeout 90 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$Q" >/dev/null 2>&1
    if ! kill -0 $srv 2>/dev/null; then
        echo "DIFF $1: THE SERVER PROCESS DIED - a client statement took it down"
        tail -3 "/tmp/fc-serve-deep-$PORT.log" | sed 's/^/     /'
        fail=1
        return 1
    fi
    if [ "$(alive)" != "3" ]; then
        echo "DIFF $1: the process lives but a SECOND connection cannot query it"
        fail=1
        return 1
    fi
    echo "OK   $1: server alive, a second connection still answers"
}
# ...and where both servers answer, the ANSWERS must agree too
agrees() { # <label> <sql>
    ran=$((ran + 1))
    printf 'SET HEADING OFF;\n%s;\n' "$2" > "$Q"
    local e c
    e=$(timeout 90 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$Q" 2>&1 | grep -av '^[[:space:]]*$' | tr -s ' \n' ' ')
    c=$(timeout 90 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$Q" 2>&1 | grep -av '^[[:space:]]*$' | tr -s ' \n' ' ')
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1: $(printf '%.40s' "$e")"
    else echo "DIFF $1"; echo "     engine: $(printf '%.60s' "$e")"; echo "     fcwire: $(printf '%.60s' "$c")"; fail=1; fi
}

echo "--- 1. the shapes that used to abort the process ---------------------"
survives "1000 chained ||"     "SELECT OCTET_LENGTH($(chain x '||' 1000 "'a'")) AS X FROM RDB\$DATABASE"
survives "2000 chained ||"     "SELECT OCTET_LENGTH($(chain x '||' 2000 "'a'")) AS X FROM RDB\$DATABASE"
survives "5000 chained ||"     "SELECT OCTET_LENGTH($(chain x '||' 5000 "'a'")) AS X FROM RDB\$DATABASE"
survives "1000 chained +"      "SELECT $(chain x '+' 1000 '1') AS X FROM RDB\$DATABASE"
survives "2000 chained +"      "SELECT $(chain x '+' 2000 '1') AS X FROM RDB\$DATABASE"
survives "1200 nested parens"  "SELECT $(python3 -c "print('('*1200 + '1' + ')'*1200)") AS X FROM RDB\$DATABASE"
survives "2000 nested parens"  "SELECT $(python3 -c "print('('*2000 + '1' + ')'*2000)") AS X FROM RDB\$DATABASE"
survives "a deep chain in a WHERE" \
    "SELECT ID FROM T WHERE $(chain x '+' 1500 '1') > 0 ORDER BY ID"

echo "--- 2. the depths the engine answers, fire-crab must answer too ------"
agrees "50 chained ||"    "SELECT OCTET_LENGTH($(chain x '||' 50 "'a'")) AS X FROM RDB\$DATABASE"
agrees "200 chained ||"   "SELECT OCTET_LENGTH($(chain x '||' 200 "'a'")) AS X FROM RDB\$DATABASE"
agrees "800 chained ||"   "SELECT OCTET_LENGTH($(chain x '||' 800 "'a'")) AS X FROM RDB\$DATABASE"
agrees "1000 chained ||"  "SELECT OCTET_LENGTH($(chain x '||' 1000 "'a'")) AS X FROM RDB\$DATABASE"
agrees "2000 chained ||"  "SELECT OCTET_LENGTH($(chain x '||' 2000 "'a'")) AS X FROM RDB\$DATABASE"
agrees "1000 chained +"   "SELECT $(chain x '+' 1000 '1') AS X FROM RDB\$DATABASE"
agrees "2000 chained +"   "SELECT $(chain x '+' 2000 '1') AS X FROM RDB\$DATABASE"
agrees "400 nested parens" "SELECT $(python3 -c "print('('*400 + '1' + ')'*400)") AS X FROM RDB\$DATABASE"
agrees "an ordinary expression (control)" "SELECT ID + 1, S || 'x' FROM T ORDER BY ID"

echo "----------------------------------------------------------------------"
echo "ran $ran checks"
[ "$ran" -ge 17 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
