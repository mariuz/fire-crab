#!/bin/bash
# THE ANNOUNCED NULLABLE BIT through a VIEW and through a GROUPED JOIN.
#
# Two describe defects, unrelated to each other except that both are the
# nullable bit and both were found while chasing something else. Neither
# is cosmetic: in this server the announced bit decides whether a value's
# bytes go on the wire at all, so a wrong bit is a wrong VALUE.
#
# 1. EVERY COLUMN OF A VIEW IS NULLABLE, whatever its body says.
#    `plan_view` took the body's columns verbatim and touched `sql_type`
#    nowhere, so a view over a NOT NULL column announced NOT NULL. The
#    engine's rule is UNCONDITIONAL - measured over a plain NOT NULL
#    column, a DOMAIN-typed one, an expression, through a WHERE,
#    view-over-view, aliased, and nested inside a derived table. It
#    agrees with the catalogue, where a view's RDB$RELATION_FIELDS row
#    carries no RDB$NULL_FLAG at all.
#
# 2. A GROUPED JOIN WAS NEVER MARKED NOT NULL AT ALL. The grouped branch
#    of the join planner returns some 230 lines BEFORE the only
#    `mark_not_null_join` call, so `SELECT W.NN, COUNT(*) FROM W JOIN W2
#    ... GROUP BY W.NN` announced a NOT NULL key as Nullable - while the
#    same query WITHOUT the join was already correct. No nested source is
#    involved; plain base tables are enough.
#
# THE TWO INTERACT, and the interaction is why they are gated together.
# `SELECT V.ID, V.NN FROM <view> V JOIN W ON ...` agreed with the engine
# BEFORE either fix and must still agree after: the join side discards a
# column's bit at the boundary, so the view's wrong NOT NULL never
# reached the describe. A fix that made the join side CARRY the bit
# without fixing the view would have broken exactly this shape - which is
# why it is here, with the plain view beside it.
#
# THE FENCES. An outer-joined side's key must stay Nullable, and a
# grouped key on the null-extended side of a LEFT or RIGHT join is the
# case that catches a marker being handed the wrong field: a grouped
# column's field_id indexes the GROUP ROW, not the joined record, so
# asking the join marker about it directly is right for an inner join by
# luck and wrong for an outer one.
#
# NOT FIXED, and deliberately: a NOT NULL column reached through a
# derived table or CTE - by a CAST, by `N + 0`, or joined to a base
# table - was REPORTED divergent and measured AGREEING on all four
# shapes. Those are checked below as controls so that a future change
# which breaks them is caught.
#
#   qa/serve-real-nullbit.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4357}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-nullbit-a.fdb"
B="$D/fc-nullbit-b.fdb"

mkdir -p "$D"
setup() {
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE DOMAIN DNN AS INTEGER NOT NULL;
CREATE TABLE W (ID INTEGER NOT NULL, NN INTEGER NOT NULL, DM DNN, NU INTEGER);
COMMIT;
INSERT INTO W VALUES (1,10,100,7);
INSERT INTO W VALUES (2,20,200,NULL);
COMMIT;
CREATE VIEW VP AS SELECT ID, NN, DM, NU FROM W;
CREATE VIEW VE AS SELECT ID, NN+0 AS E, CAST(NN AS INTEGER) AS C FROM W;
CREATE VIEW VW AS SELECT ID, NN FROM W WHERE NN > 0;
CREATE VIEW VV AS SELECT ID, NN FROM VP;
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0; while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nullbit.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

fail=0; ran=0
FC="127.0.0.1/$PORT:$A"
EN="127.0.0.1/3050:$B"

# PREPARE only - this is a describe law and the values are identical
# throughout, which is exactly why a value comparison would miss it
dsc() { # <dsn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\nSET PLANONLY ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype' | sed 's/  */ /g' | tr '\n' '|'
}
both() { # <label> <sql>
    ran=$((ran + 1))
    e=$(dsc "$EN" "$2"); c=$(dsc "$FC" "$2")
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}

echo "--- 1. every column of a view is Nullable ---------------------------"
both "a view over NOT NULL, DOMAIN NOT NULL and nullable columns" \
    "SELECT ID, NN, DM, NU FROM VP"
both "a view over expressions"          "SELECT ID, E, C FROM VE"
both "a view with a WHERE"              "SELECT ID, NN FROM VW"
both "a view over a view"               "SELECT ID, NN FROM VV"
both "an aliased view"                  "SELECT V.NN FROM VP V"
both "a view inside a derived table"    "SELECT D.NN FROM (SELECT NN FROM VP) D"
both "COUNT over a view, which has its own rule" "SELECT COUNT(*) FROM VP"
# the base table is the contrast: NOT NULL stays NOT NULL
both "the base table, unchanged"        "SELECT ID, NN, DM, NU FROM W"

echo "--- 2. a grouped join is marked like an ungrouped one ----------------"
both "a grouped inner join"             "SELECT W.NN, COUNT(*) C FROM W JOIN W W2 ON W.ID=W2.ID GROUP BY W.NN"
both "two grouped keys"                 "SELECT W.ID, W.NN, COUNT(*) C FROM W JOIN W W2 ON W.ID=W2.ID GROUP BY W.ID, W.NN"
both "an expression key over a join"    "SELECT W.NN+0 E, COUNT(*) C FROM W JOIN W W2 ON W.ID=W2.ID GROUP BY 1"
both "a text expression key"            "SELECT UPPER(CAST(W.NN AS VARCHAR(4))) E, COUNT(*) C FROM W JOIN W W2 ON W.ID=W2.ID GROUP BY 1"
both "a nullable grouped key"           "SELECT W.NU, COUNT(*) C FROM W JOIN W W2 ON W.ID=W2.ID GROUP BY W.NU"
# the fences: a null-extended side stays Nullable. These are the checks
# that catch the marker being asked about the wrong field - a grouped
# column's field_id indexes the GROUP ROW, not the joined record, so
# asking directly is right for an inner join by luck and wrong here.
both "a LEFT join's LEFT key"           "SELECT W.NN, COUNT(*) C FROM W LEFT JOIN W W2 ON W.ID=W2.ID GROUP BY W.NN"
both "a LEFT join's NULL-EXTENDED key"  "SELECT W2.NN, COUNT(*) C FROM W LEFT JOIN W W2 ON W.ID=W2.ID GROUP BY W2.NN"
both "a RIGHT join's right key"         "SELECT W2.NN, COUNT(*) C FROM W RIGHT JOIN W W2 ON W.ID=W2.ID GROUP BY W2.NN"
both "a RIGHT join's NULL-EXTENDED key" "SELECT W.NN, COUNT(*) C FROM W RIGHT JOIN W W2 ON W.ID=W2.ID GROUP BY W.NN"
both "an expression key on a null-extended side" \
    "SELECT W2.NN+0 E, COUNT(*) C FROM W LEFT JOIN W W2 ON W.ID=W2.ID GROUP BY 1"
both "grouped with NO join, the control" "SELECT NN, COUNT(*) C FROM W GROUP BY NN"
both "an ungrouped join, the control"    "SELECT W.NN FROM W JOIN W W2 ON W.ID=W2.ID"

echo "--- 3. the interaction, and the shapes NOT changed -------------------"
# agreed BEFORE either fix and must still agree: the join side discards
# the bit, so the view's wrong NOT NULL never reached the describe
both "a view JOINED to a base table"    "SELECT VP.ID, VP.NN FROM VP JOIN W ON W.ID=VP.ID"
# reported divergent, measured AGREEING - kept as controls
both "a bare pass-through out of a derived" "SELECT D.NN FROM (SELECT NN FROM W) D"
both "a CAST through a derived"         "SELECT D.X FROM (SELECT CAST(NN AS INTEGER) X FROM W) D"
both "an expression through a derived"  "SELECT D.X FROM (SELECT NN+0 X FROM W) D"
both "a derived JOINED to a base table" "SELECT D.NN FROM (SELECT NN FROM W) D JOIN W ON W.ID=D.NN"
both "a CTE joined to a base table"     "WITH C AS (SELECT NN FROM W) SELECT C.NN FROM C JOIN W ON W.ID=C.NN"
both "a LEFT-joined derived stays Nullable" \
    "SELECT D.NN FROM W LEFT JOIN (SELECT NN FROM W) D ON D.NN=W.ID"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 26 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
