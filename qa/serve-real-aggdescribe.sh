#!/bin/bash
# An aggregate DESCRIBES its source's type - the roadmap's oldest
# recorded describe divergence, measured shape by shape:
#
#   * MIN and MAX carry the SOURCE column's own type: over an INTEGER
#     they describe 496 LONG, over a SMALLINT 500 SHORT, over a BIGINT
#     580 INT64 - lone, and as a scalar subquery in a projection;
#   * SUM and AVG widen to INT64 (580) regardless of source;
#   * COUNT(*) and COUNT(col) are INT64 and the ONE aggregate the
#     engine announces NOT NULLABLE (580 even, no Nullable flag);
#   * an aggregate inside arithmetic (MAX(I) + 1) widens to INT64.
#
# The check is isql's own SQLDA_DISPLAY: the sqltype lines ARE the
# describe, and the fetched row underneath proves the WIRE SLOT matches
# the announcement (a MIN/MAX that says LONG must travel in XDR's
# 4-byte slot - saying one thing and sending another desyncs every
# driver).
#
#   qa/serve-real-aggdescribe.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4729}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-aggdesc-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

mkdb() {
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (S SMALLINT, I INTEGER, B BIGINT);
COMMIT;
INSERT INTO T VALUES (1, 100000, 9000000000);
INSERT INTO T VALUES (2, 5, 7);
COMMIT;
EOF
}
EDB="$D/fc-aggd-e.fdb"
FDB="$D/fc-aggd-f.fdb"
rm -f "$EDB" "$FDB"
mkdb "localhost:$EDB"
mkdb "$FDB"
chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
E="localhost:$EDB"
F="127.0.0.1/$PORT:$FDB"
sq() { # <conn> <sql> - the SQLDA lines and the rows, together
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -vE "^Version|^Server|^Client" | tr -s ' \n' ' '
}
both() { check "$1" "$(sq "$F" "$2")" "$(sq "$E" "$2")"; }

both "MAX over INTEGER describes LONG"        "SELECT MAX(I) FROM T;"
both "MAX over SMALLINT describes SHORT"      "SELECT MAX(S) FROM T;"
both "MIN over BIGINT stays INT64"            "SELECT MIN(B) FROM T;"
both "SUM widens to INT64 whatever the source" "SELECT SUM(S) FROM T;"
both "COUNT(*) is INT64 and NOT nullable"     "SELECT COUNT(*) FROM T;"
both "COUNT(col) the same"                    "SELECT COUNT(I) FROM T;"
both "an aliased MIN keeps the type and the alias" "SELECT MIN(S) AS LO FROM T;"
both "a filtered MAX keeps the type"          "SELECT MAX(I) FROM T WHERE S = 2;"

# --- the grouped half, and the subquery-in-projection half ---------------------
both "grouped MAX keeps the source type"      "SELECT S, MAX(I) FROM T GROUP BY S;"
both "grouped MIN over SMALLINT"              "SELECT I, MIN(S) FROM T GROUP BY I;"
both "grouped COUNT is NOT nullable"          "SELECT S, COUNT(*) FROM T GROUP BY S;"
both "grouped SUM widens"                     "SELECT S, SUM(I) FROM T GROUP BY S;"
both "HAVING changes nothing"                 "SELECT S, MAX(I) FROM T GROUP BY S HAVING MAX(I) > 1;"
# a WHOLE-ITEM subquery lends the outer column its type - and a
# subquery result is ALWAYS nullable, even COUNT (no row answers NULL)
both "a subquery MAX describes its source"    "SELECT (SELECT MAX(I) FROM T) AS M FROM T;"
both "a subquery MIN over SMALLINT"           "SELECT (SELECT MIN(S) FROM T) FROM T;"
both "a subquery COUNT turns NULLABLE"        "SELECT S, (SELECT COUNT(*) FROM T) FROM T;"

echo "ran $ran checks"
exit $fail
