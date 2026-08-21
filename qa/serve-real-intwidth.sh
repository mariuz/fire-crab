#!/bin/bash
# The WIDTH an integer-valued expression describes (sqltype 500 SHORT /
# 496 LONG / 580 INT64), probed: an integer literal is LONG when it fits
# 32 bits and BIGINT beyond; arithmetic widens to BIGINT; negation keeps;
# CASE / IIF / COALESCE take their widest branch (a literal counting as
# LONG); NULLIF takes its FIRST argument's type; ABS widens one step, MOD
# keeps its first argument's. Every statement runs through isql with
# SQLDA display on both servers and the type lines and values compared.
#
#   qa/serve-real-intwidth.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4879}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-intwidth-crab.fdb"
B="$D/fc-intwidth-engine.fdb"
LOG="/tmp/fc-serve-intwidth-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE W (S SMALLINT, I INTEGER, B BIGINT, N NUMERIC(9,2), V VARCHAR(5));
COMMIT;
INSERT INTO W VALUES (1, 2, 3, 4.5, 'x');
INSERT INTO W VALUES (-7, NULL, 40000000000, NULL, NULL);
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
      | grep -v '^$' | grep -v '^  :' | grep -v '^=' | sed 's/  */ /g; s/ *$//; s/ subtype: 0 len: [0-9]*.*//' | tr '\n' '|'
}
while IFS= read -r q; do
    [ -z "$q" ] && continue
    e=$(run "127.0.0.1/$REAL:$B" "$q"); c=$(run "127.0.0.1/$PORT:$A" "$q")
    check "$q" "$c" "$e"
done <<'SQL'
SELECT 5, -5, 32767, 32768, 2147483647, 2147483648, -(5), 10000000000 FROM W WHERE S = 1;
SELECT 1 + 2, 5 * 2, 5 / 2, S + 1, S * 2, S + S, I + I, -S, B + 1 FROM W ORDER BY S;
SELECT CASE WHEN S > 0 THEN 1 ELSE 2 END, CASE WHEN S > 0 THEN S ELSE 2 END, CASE WHEN S > 0 THEN S ELSE S END, CASE WHEN S > 0 THEN B ELSE 1 END, CASE WHEN S > 0 THEN 1 ELSE 2147483648 END, CASE WHEN S > 0 THEN 1 END FROM W ORDER BY S;
SELECT COALESCE(S, 0), COALESCE(I, 0), COALESCE(B, 0), COALESCE(S, I), COALESCE(S, B), COALESCE(I, S) FROM W ORDER BY S;
SELECT IIF(S > 0, S, 1), IIF(S > 0, 1, 2), IIF(S > 0, B, S), NULLIF(S, 1), NULLIF(I, 1), NULLIF(1, S), NULLIF(B, 3) FROM W ORDER BY S;
SELECT ABS(S), ABS(I), MOD(I, 2), MOD(S, 2), ABS(B) FROM W ORDER BY S;
SELECT S FROM W WHERE COALESCE(I, 0) = 0;
SQL
echo "ran $ran checks"
exit $fail
