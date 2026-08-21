#!/bin/bash
# CURRENT_TIME / CURRENT_TIMESTAMP in a select list: TIME / TIMESTAMP WITH
# TIME ZONE (32756 len 8 / 32754 len 12, probed), in the SESSION zone -
# the server's OS zone, which both servers on this box share - with an
# optional precision (CURRENT_TIME defaults to 0 fractional digits,
# CURRENT_TIMESTAMP to 3), never nullable; LOCALTIME / LOCALTIMESTAMP stay
# the zone-less forms. The clock differs between the two servers by
# construction, so the digits of the time of day are normalised and the
# DESCRIBE, the zone and the shape are what is compared.
#
#   qa/serve-real-currenttime.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4877}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-currenttime-crab.fdb"
B="$D/fc-currenttime-engine.fdb"
LOG="/tmp/fc-serve-currenttime-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY);
COMMIT;
INSERT INTO T VALUES (1);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
run() { # <conn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
      | grep -v '^$' | grep -v '^  : table' | sed 's/  */ /g; s/ *$//' \
      | sed 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]*/HH:MM:SS.ffff/g; s/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]/YYYY-MM-DD/g' | tr '\n' '|'
}
while IFS= read -r q; do
    [ -z "$q" ] && continue
    e=$(run "127.0.0.1/$REAL:$B" "$q"); c=$(run "127.0.0.1/$PORT:$A" "$q")
    check "$q" "$c" "$e"
done <<'SQL'
SELECT CURRENT_TIME FROM T;
SELECT CURRENT_TIMESTAMP FROM T;
SELECT CURRENT_TIME(0), CURRENT_TIMESTAMP(3) FROM T;
SELECT CURRENT_TIMESTAMP(0) FROM T;
SELECT CURRENT_TIMESTAMP AS NOW_TS, CURRENT_TIME AS NOW_T, LOCALTIMESTAMP, LOCALTIME, CURRENT_DATE FROM T;
SELECT ID, CURRENT_TIMESTAMP FROM T WHERE ID = 1;
SELECT CURRENT_TIMESTAMP FROM RDB$DATABASE;
SQL
ran=$((ran + 1))
f=$(printf "SELECT CURRENT_TIME, CURRENT_TIMESTAMP(0) FROM T;\n" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -c '\.0000')
if [ "$f" -ge 1 ]; then echo "OK   fc zeroes the fraction at precision 0"; else echo "DIFF fc zeroes the fraction at precision 0"; fail=1; fi
echo "ran $ran checks"
exit $fail
