#!/bin/bash
# A projected CONSTANT in a GROUPED query - SELECT 42, COUNT(*) FROM T
# GROUP BY V. The engine answers a constant (a literal or a constant
# expression, referencing no column) once per group; this server refused
# ANY non-key projected expression with a bare "Dynamic SQL Error". The
# group builder now recognises a column-free item, gives it a placeholder
# group slot and carries the expression on its output column, so the
# constant rides through the fold untouched.
#
# Covered across all three grouped shapes (they share build_group_items):
# plain GROUP BY, an implicit whole-table aggregate, a grouped JOIN and a
# grouped derived table. A constant anywhere in the select list, alone, or
# beside keys and aggregates.
#
# This is the prerequisite for a `?` projection parameter in a grouped
# query (a typed CAST(? AS ..) is a column-free item too) - that rides on
# this in its own slice.
#
# BOUNDARY (left out, still refused): an expression OVER a grouping column
# - SELECT V*2 ... GROUP BY V - which the engine answers (V is
# functionally determined) but this server does not yet; it needs the
# expression evaluated over the group's key slots, a separate slice.
#
#   qa/serve-real-groupconst.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4751}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
CREATE TABLE U (ID INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10); INSERT INTO T VALUES (2,10); INSERT INTO T VALUES (3,20);
INSERT INTO U VALUES (1,100); INSERT INTO U VALUES (3,300);
COMMIT;
EOF
}
EDB="$D/fc-groupconst-e.fdb"; FDB="$D/fc-groupconst-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-groupconst-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

# reduce an answer to its numbers, or the ERROR CLASS, so spacing and the
# engine's longer message text never read as a divergence
red() { printf 'SET HEADING OFF;\n%s;\n' "$2" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
    grep -v '^$' | grep -oiE 'error|-?[0-9]+' | tr '\n' ' '; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { # <sql>
    local e c
    e=$(red "$E" "$1"); c=$(red "$F" "$1")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
# a constant anywhere: leading, between key and aggregate, trailing
both "SELECT 42, COUNT(*) FROM T GROUP BY V"
both "SELECT V, 42, COUNT(*) FROM T GROUP BY V"
both "SELECT COUNT(*), 42 FROM T GROUP BY V"
# a constant EXPRESSION folds to its value
both "SELECT 1+2, COUNT(*) FROM T GROUP BY V"
# a constant-only grouped projection (no aggregate in the list)
both "SELECT 42 FROM T GROUP BY V"
# the implicit whole-table aggregate takes a constant too
both "SELECT 42, SUM(V) FROM T"
both "SELECT 42, COUNT(*) FROM T"
# beside a key and an aggregate, with an ORDER BY
both "SELECT V, 99, SUM(V) FROM T GROUP BY V ORDER BY V"
# a grouped JOIN and a grouped DERIVED table (same builder)
both "SELECT 7, COUNT(*) FROM T JOIN U ON T.ID = U.ID GROUP BY T.V"
both "SELECT 7, COUNT(*) FROM (SELECT V FROM T) X GROUP BY X.V"
# an invalid non-key COLUMN stays refused on both (ID is not grouped) -
# the engine's message is longer, so this is pinned as "both refuse"
refuses() { # <sql>
    local e c
    e=$(printf 'SET HEADING OFF;\n%s;\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$E" 2>&1 | grep -c 'Statement failed')
    c=$(printf 'SET HEADING OFF;\n%s;\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$F" 2>&1 | grep -c 'Statement failed')
    ran=$((ran + 1))
    if [ "$e" -ge 1 ] && [ "$c" -ge 1 ]; then echo "OK   $1 refuses on both"
    else echo "DIFF $1  engine_fail=$e fcrab_fail=$c"; fail=1; fi
}
refuses "SELECT ID, COUNT(*) FROM T GROUP BY V"

echo "ran $ran checks"
exit $fail
