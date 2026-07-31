#!/bin/bash
# TEXT COLUMN WIDTHS in the describe - what a client renders a column
# at. fire-crab used to declare every text column at the SQL_VARYING
# maximum (32765) because wire_for had no TEXT/VARYING arm and fell into
# its catch-all, so isql padded EVERY value to 32765 characters: a few
# thousand rows weigh hundreds of megabytes, which is what made the
# firebird-qa isql init scripts look like hangs (subprocess.run churning
# through the output until the harness timed out).
#
# A VARYING descriptor's stored length carries the 2-byte count word, a
# TEXT (CHAR) one does not; charset NONE here, so byte length ==
# character length.
#
# THE DIFFERENTIAL: the SAME isql binary selects the same columns from
# the same file through the engine and through fire-crab, and the
# rendered LINE WIDTHS must match - which is the describe's declared
# width, observable without any protocol tooling. Plus a size ceiling:
# many rows of text must not blow the output up.
#
#   qa/serve-real-textwidth.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4293}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-tw.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V5 VARCHAR(5), V40 VARCHAR(40), C8 CHAR(8));
COMMIT;
INSERT INTO T VALUES (1, 'ab', 'hello', 'xy');
INSERT INTO T VALUES (2, 'cde', 'world', 'zw');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-tw.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
# the widest rendered line for a query - the declared width in practice
width() { # <dsn> <select>
    printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | awk '{print length($0)}' | sort -rn | head -1
}

for q in "SELECT V5 FROM T" "SELECT V40 FROM T" "SELECT C8 FROM T" \
         "SELECT V5, C8 FROM T" "SELECT V40 FROM T WHERE ID = 1"; do
    eng=$(width "$DB" "$q")
    fc=$(width "127.0.0.1/$PORT:$DB" "$q")
    check "width matches the engine [$q]" "$fc" "$eng"
done

# the teeth: the widths must be the SMALL declared ones, not the maximum
# (a vacuous pass would be both sides reporting 32766)
w5=$(width "127.0.0.1/$PORT:$DB" "SELECT V5 FROM T")
case "$w5" in
    3|4|5|6|7) echo "OK   teeth: VARCHAR(5) renders ~5 wide, not the 32765 maximum ($w5)" ;;
    *) echo "DIFF VARCHAR(5) width is $w5"; fail=1 ;;
esac

# and the size ceiling that made init scripts look like hangs: 200 rows
# of text must stay small (it was ~30KB PER ROW before)
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<'SQL'
INSERT INTO T SELECT 9, 'zz', 'padding-check', 'qq' FROM RDB$TYPES ROWS 200;
COMMIT;
SQL
bytes=$(printf 'SET HEADING OFF;\nSELECT V40 FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | wc -c)
if [ "$bytes" -lt 20000 ]; then
    echo "OK   200+ text rows weigh $bytes bytes (the maximum-width bug made this megabytes)"
else
    echo "DIFF 200 text rows produced $bytes bytes"; fail=1
fi
engb=$(printf 'SET HEADING OFF;\nSELECT V40 FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | wc -c)
check "the whole result set is the same size as the engine's" "$bytes" "$engb"

exit $fail
