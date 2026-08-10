#!/bin/bash
# CAST(? AS <type>) in the SELECT LIST of a JOIN. The projection `?` cast
# landed for a plain single-table SELECT (qa/serve-real-castparam.sh) and
# its temporal targets followed (qa/serve-real-castparamt.sh); this slice
# extends the `?` projection param to a JOINed query, where the select
# list resolves against the COMBINED row rather than one table.
#
#   * the `?` slot DESCRIBES as the cast target and the joined output
#     columns keep their own types - measured against the live engine
#     with qa/fbdesc.c;
#   * a value-derived VARCHAR bound into the projection slot converts by
#     the cast and the joined rows come back unchanged - a MULTI-ROW
#     value differential via qa/fbparamj.c, which reads each output
#     column in its ANNOUNCED integer width (no server-side coercion);
#   * a projection `?` and a WHERE `?` COEXIST, numbered in ONE textual
#     order (projection first, WHERE after) exactly as the plain path
#     does - the join now offsets its WHERE numbering past the projection
#     params instead of starting at zero;
#   * a bare/inner/left join, two projection params, and one nested in
#     arithmetic (T.V + CAST(? AS INTEGER)) all hold.
#
# SCOPE: the non-grouped join projection. A GROUP BY / aggregate or a
# derived-table projection param is a separate follow-up (those builders
# still refuse a `?`).
#
#   qa/serve-real-castparamjoin.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4747}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbparamj"; DESC="$D/fc-fbdescj"
if ! cc -o "$RIG" "$(dirname "$0")/fbparamj.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the join param rig (cc/libfbclient missing)"; exit 0
fi
cc -o "$DESC" "$(dirname "$0")/fbdesc.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null || DESC=""
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
CREATE TABLE U (ID INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10); INSERT INTO T VALUES (2,20);
INSERT INTO U VALUES (1,100); INSERT INTO U VALUES (2,200);
COMMIT;
EOF
}
EDB="$D/fc-castparamjoin-e.fdb"; FDB="$D/fc-castparamjoin-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castparamjoin-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$DESC" "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"

# --- the value differential: every joined row, its integer columns ------------
both() { # <sql> <projval> <whereval-or-empty> <label>
    local e c
    e=$(timeout 15 "$RIG" "$E" "$1" "$2" "$3" 2>&1)
    c=$(timeout 15 "$RIG" "$F" "$1" "$2" "$3" 2>&1)
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   [$4 <- '$2'${3:+/'$3'}] => $(echo "$e" | tr '\n' '|')"
    else echo "DIFF [$4]"; echo "     engine: $(echo "$e" | tr '\n' '|')"; echo "     fcrab:  $(echo "$c" | tr '\n' '|')"; fail=1; fi
}
J="SELECT CAST(? AS INTEGER), T.V FROM T JOIN U ON T.ID=U.ID"
both "$J"                                     "2.5"  ""  "inner join, rounding"
both "$J ORDER BY T.V"                         "1e2"  ""  "inner join, exponent + order"
both "SELECT CAST(? AS SMALLINT), T.V FROM T LEFT JOIN U ON T.ID=U.ID" "42" "" "left join smallint"
both "SELECT CAST(? AS BIGINT), T.V FROM T JOIN U ON T.ID=U.ID"        "9999999999" "" "join bigint"
# a projection `?` AND a WHERE `?`, ONE textual order (proj first)
both "$J WHERE T.ID = ?"                       "7.9"  "2" "join proj + WHERE, textual order"
# two projection params, one nested in arithmetic
both "SELECT CAST(? AS INTEGER), T.V + CAST(? AS INTEGER) FROM T JOIN U ON T.ID=U.ID" "5" "" "two proj params, nested"
# a width overflow on the bound value still raises, both sides
both "SELECT CAST(? AS SMALLINT), T.V FROM T JOIN U ON T.ID=U.ID" "99999" "" "join width overflow"

# --- the describe: the `?` slot IS the cast target, joined cols keep type -----
if [ -n "$DESC" ]; then
    dboth() { # <sql> <label>
        local e c
        e=$("$DESC" "$E" "$1" 2>&1)
        c=$("$DESC" "$F" "$1" 2>&1)
        ran=$((ran + 1))
        if [ "$e" = "$c" ]; then echo "OK   describe $2 [$(echo "$e" | tr '\n' ' ')]"
        else echo "DIFF describe $2"; echo "     engine: $e"; echo "     fcrab:  $c"; fail=1; fi
    }
    dboth "$J" "CAST(? AS INTEGER), T.V (join)"
    dboth "$J WHERE T.ID = ?" "join proj + WHERE param slots"
fi

echo "ran $ran checks"
exit $fail
