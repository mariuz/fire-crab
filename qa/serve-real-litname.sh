#!/bin/bash
# A SELECT of an UNALIASED STRING LITERAL WITH NON-ASCII BYTES does not
# drop the connection.
#
# fire-crab derives an implicit column name for a select item by splitting
# its text on the last whitespace to spot a trailing alias. That split
# matched UNICODE whitespace and then advanced one BYTE past it - but a
# multibyte literal under a NONE attachment (its UTF-8 high bytes read one
# char per byte) decodes a 0xA0 to U+00A0 NBSP, a two-byte whitespace
# char, so the one-byte advance landed inside the char and PANICKED,
# dropping the connection (SQLSTATE 08006) on `SELECT '<non-ascii>' FROM
# RDB$DATABASE`. An ASCII-only split fixes it; the column is named
# CONSTANT and the value is returned, as the engine does.
#
# Read against the engine over a NONE database; both must return the same
# value and column name and neither may drop the connection.
#
# Usage: qa/serve-real-litname.sh [port]   (default 4139)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4139}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/litname.fdb"
rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-litname.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
both() { # <query>
    local q="$1" a b
    a=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" <<< "$q" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" <<< "$q" 2>&1 | sed 's/[[:space:]]*$//')
    if printf '%s' "$b" | grep -q '08006'; then echo "FAIL [$q] fire-crab dropped the connection"; fail=1; return; fi
    if [ "$a" = "$b" ]; then echo "OK   [$q]"; else echo "FAIL [$q]"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'; fail=1; fi
}
both "select 'abc' from rdb\$database;"
both "select 'à' from rdb\$database;"
both "select 'àé' from rdb\$database;"
both "select 'ààà' from rdb\$database;"
both "select 'café crème' from rdb\$database;"
both "select 'x' || 'àé' from rdb\$database;"
both "select 'àé' as lbl from rdb\$database;"
both "select upper('àé') from rdb\$database;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS litname" || echo "FAIL litname"
exit $fail
