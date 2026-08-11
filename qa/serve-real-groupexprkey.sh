#!/bin/bash
# An EXPRESSION OVER A GROUPING COLUMN in a grouped select list - V*2 or
# UPPER(NM) when the group is BY V / BY NM. The engine answers it by
# functional dependence (every column the expression reads is a grouping
# column, so it is constant within a group); this server refused any
# projected expression that was not the group key ITSELF.
#
# The group builder now DEFERS such an expression to its second pass -
# the same pass that folds aggregates - which resolves it over the group
# row's key slots. An expression naming a NON-grouped column fails to
# resolve there and is still refused, the engine's -104.
#
# (This also flushed out a latent bug: a bare aggregate did not push to
# slot_descs, so a later APPENDED key slot - the group key when no bare
# key is selected - read the wrong, zero descriptor and the expression
# would not type. slot_descs is now kept parallel to the group items.)
#
# Covered: plain GROUP BY (bare column) and a grouped DERIVED table take
# the bare form; a grouped JOIN takes the QUALIFIED form (T.V*2 GROUP BY
# T.V) - a bare column in a join select list is a separate resolution
# nuance and is left refused.
#
#   qa/serve-real-groupexprkey.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4755}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER, NM VARCHAR(10));
CREATE TABLE U (ID INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10,'aa'); INSERT INTO T VALUES (2,10,'aa'); INSERT INTO T VALUES (3,20,'bb');
INSERT INTO U VALUES (1,100); INSERT INTO U VALUES (3,300);
COMMIT;
EOF
}
EDB="$D/fc-groupexprkey-e.fdb"; FDB="$D/fc-groupexprkey-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-groupexprkey-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

red() { printf 'SET HEADING OFF;\n%s;\n' "$2" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
    grep -v '^$' | sed 's/  */ /g;s/^ //;s/ $//' |
    grep -oiE '[A-Za-z]+|-?[0-9]+' | tr '\n' ' '; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { # <sql>
    local e c
    e=$(red "$E" "$1"); c=$(red "$F" "$1")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
# plain GROUP BY - an arithmetic or function expression over the key
both "SELECT V*2, COUNT(*) FROM T GROUP BY V"
both "SELECT V+1, COUNT(*) FROM T GROUP BY V"
both "SELECT V*2+1, SUM(V) FROM T GROUP BY V ORDER BY V"
both "SELECT UPPER(NM), COUNT(*) FROM T GROUP BY NM"
both "SELECT NM || 'x', COUNT(*) FROM T GROUP BY NM"
# the bare key AND an expression over it, beside an aggregate
both "SELECT V, V*2, SUM(V) FROM T GROUP BY V ORDER BY V"
# a grouped DERIVED table takes the bare form too
both "SELECT X.V + 5, COUNT(*) FROM (SELECT V FROM T) X GROUP BY X.V"
# a grouped JOIN takes the QUALIFIED form
both "SELECT T.V * 2, COUNT(*) FROM T JOIN U ON T.ID = U.ID GROUP BY T.V"

# an expression over a NON-grouped column stays refused on both (-104)
refuses() { # <sql>
    local e c
    e=$(printf 'SET HEADING OFF;\n%s;\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$E" 2>&1 | grep -c 'Statement failed')
    c=$(printf 'SET HEADING OFF;\n%s;\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$F" 2>&1 | grep -c 'Statement failed')
    ran=$((ran + 1))
    if [ "$e" -ge 1 ] && [ "$c" -ge 1 ]; then echo "OK   $1 refuses on both"
    else echo "DIFF $1  engine_fail=$e fcrab_fail=$c"; fail=1; fi
}
refuses "SELECT V + ID, COUNT(*) FROM T GROUP BY V"

echo "ran $ran checks"
exit $fail
