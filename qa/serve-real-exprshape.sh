#!/bin/bash
# THE SHAPE OF A COMPUTED COLUMN - four ways a projected expression gets
# its DESCRIBE wrong while still returning a row, so nothing looks broken
# until you compare with the engine's.
#
# A client never reads a row; it reads a row UNDER A DESCRIPTION. The
# value on the wire is a raw integer or a run of bytes until the
# describe's type, width, scale and sub_type say what to do with it - so
# a server can ship the right bytes and still be wrong, invisibly from
# either side alone. Every check below therefore compares the describe
# line AND the rendered value as ONE string: either half alone passes
# while the other is wrong, which is exactly how classes 3 and 4 hid
# (their VALUES are identical on both servers).
#
# All four were live WRONG ANSWERS, not refusals:
#
#  1. A COMPUTED LENGTH on SUBSTRING / LPAD / RPAD. With a literal
#     length fire-crab narrowed the describe correctly; with `FOR 5+0`,
#     `FOR ID` or a computed FROM it had no static width, fell into the
#     catch-all that announces the maximum, and - fatally - announced
#     CHARSET NONE with it. A UTF8 'straße' then travelled as one byte
#     per character: the client rendered `stra\xDF` where the engine
#     sends `stra\xC3\x9F`. The laws, probed with SQLDA_DISPLAY:
#     SUBSTRING keeps the SOURCE's own width (a substring can only
#     shrink its source), while a PAD can grow past it and falls back to
#     the widest VARCHAR the charset admits - 65533 bytes for NONE and
#     WIN1252, 65532 (16383 characters) for UTF8.
#
#  2. UNION COLUMN RECONCILIATION. `SELECT <NUMERIC(9,2)> UNION ALL
#     SELECT 100` took the first branch's scale and shipped the second
#     branch's RAW integer under it: 100 rendered as 1.00. Each branch
#     must be brought to the column the union announces, which is the
#     WIDEST BRANCH on each axis independently: type up the ladder
#     SHORT < LONG < INT64 < INT128, scale the widest, sub_type the max
#     - and one approximate branch makes the whole column a DOUBLE. The
#     wire FORM must move with the announced type: setting sql_type and
#     length while leaving `wire` alone answered 6442450944.66 for 1.50,
#     the 4-byte value landing in the high half of an 8-byte slot.
#
#  3. THE UNION'S SUB_TYPE, which is a DIFFERENT rule from its scale:
#     the MAX of the family codes (0 plain integer, 1 NUMERIC, 2
#     DECIMAL), independent of branch order and applied even when
#     nothing else needs reconciling - an INTEGER beside a NUMERIC(9,0)
#     agrees on type AND scale and still announces sub_type 1.
#
#  4. THE SUB_TYPE A FOLD CARRIES - found by the gate written for 3,
#     with no union in sight. SUM/AVG/MIN/MAX over a NUMERIC answer
#     sub_type 1 and over a DECIMAL 2; fire-crab announced 0 for every
#     one of them. MIN/MAX keep the source's WIDTH too, since they
#     select an existing value rather than accumulating one.
#
#  ... and, alongside them, ORDER BY AN OUTPUT ALIAS that shadows a base
#     column: `SELECT ID AS QTY FROM T ORDER BY QTY` sorted by the
#     table's own QTY instead of by the projection, so the rows came
#     back in a plausible - and wrong - order.
#
#   qa/serve-real-exprshape.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4331}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-exprshape.fdb"

# A previous run's `rm` can land while the engine is still closing its
# own attachment to the same path, and the next CREATE DATABASE then
# fails on a file that is gone from the directory but not yet from the
# engine (seen twice, as an intermittent "FAIL create" on a gate that
# passes on the next run). Drop it through the engine first and only
# then unlink, and retry the create rather than reporting a failure that
# is really a race with the run before.
mkdir -p "$D"
printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$DB" >/dev/null 2>&1
rm -f "$DB"
create() {
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE S (ID INTEGER, V20 VARCHAR(20), C6 CHAR(6),
                VN VARCHAR(20) CHARACTER SET NONE,
                VW VARCHAR(20) CHARACTER SET WIN1252,
                N92 NUMERIC(9,2), N154 NUMERIC(15,4), D92 DECIMAL(9,2),
                I128 NUMERIC(30,4), SI SMALLINT, BI BIGINT, F DOUBLE PRECISION,
                II INTEGER, QTY INTEGER);
COMMIT;
INSERT INTO S VALUES (1, 'straße eis', 'abçd', 'abc', 'abc', 7.00, 7.0000, 3.25, 11.0000, 2, 9, 2.5, 7, 30);
INSERT INTO S VALUES (2, 'zebra', 'zz', 'zzz', 'zzz', 1.50, 1.5000, 9.75, 4.0000, 3, 8, 0.5, 1, 20);
INSERT INTO S VALUES (3, 'apple', 'aa', 'aaa', 'aaa', 2.25, 2.2500, 4.50, 6.0000, 4, 7, 1.5, 2, 10);
COMMIT;
EOF
}
n=0
while [ $n -lt 4 ]; do
    err=$(create) && break
    n=$((n + 1)); rm -f "$DB"; sleep 1
done
[ $n -lt 4 ] || { echo "FAIL create: $err"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exprshape.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "SOMETHING is listening" is not "OUR server is listening" - if the
# port was taken, fcwire died at bind and every check below would run
# against the other server and pass while measuring nothing.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0; ran=0
FC="127.0.0.1/$PORT:$DB"

# the DESCRIBE line plus the rendered VALUES, as one comparable string:
# the shape a client is told and the bytes it actually gets, together -
# either half alone would have passed while the other was wrong.
shape() { # <dsn> <select>
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype|^[A-Z0-9_]+ +' | od -An -c | tr -s ' \n' ' '
}
both() { # <label> <select>
    ran=$((ran + 1))
    e=$(shape "$DB" "$2"); c=$(shape "$FC" "$2")
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}
# a shape fire-crab must REFUSE rather than answer wrongly. The engine
# ANSWERING is asserted too, so this cannot pass by both sides failing
# for some unrelated reason.
refuses() { # <label> <select>
    ran=$((ran + 1))
    c=$(printf 'SET LIST ON;\n%s;\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1)
    e=$(printf 'SET LIST ON;\n%s;\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1)
    case "$e" in *"Statement failed"*) echo "DIFF $1: the ENGINE refused too, the check is vacuous"; fail=1; return ;; esac
    case "$c" in
        *"Statement failed"*) echo "OK   refused (recorded boundary): $1" ;;
        *) echo "DIFF $1 ANSWERED where it cannot reconcile: $(printf '%s' "$c" | tr -s ' \n' ' ')"; fail=1 ;;
    esac
}

echo "--- 1. computed-length SUBSTRING / LPAD / RPAD -----------------------"
# the controls: a LITERAL length, which was always right
both "SUBSTRING with a literal FOR"      "SELECT SUBSTRING(V20 FROM 1 FOR 5) X FROM S WHERE ID=1"
both "LPAD with a literal length"        "SELECT LPAD(V20,10) X FROM S WHERE ID=1"
# the regressions
both "SUBSTRING FOR a computed length"   "SELECT SUBSTRING(V20 FROM 1 FOR 5+0) X FROM S WHERE ID=1"
both "SUBSTRING FOR a column"            "SELECT SUBSTRING(V20 FROM 1 FOR ID) X FROM S WHERE ID=1"
both "SUBSTRING with a computed FROM"    "SELECT SUBSTRING(V20 FROM 1+0) X FROM S WHERE ID=1"
both "SUBSTRING over a CHAR source"      "SELECT SUBSTRING(C6 FROM 1 FOR 2+0) X FROM S WHERE ID=1"
both "SUBSTRING over a NONE source"      "SELECT SUBSTRING(VN FROM 1 FOR 5+0) X FROM S WHERE ID=1"
both "LPAD with a computed length"       "SELECT LPAD(V20,10+0) X FROM S WHERE ID=1"
both "RPAD with a computed length"       "SELECT RPAD(V20,ID+9) X FROM S WHERE ID=1"
both "LPAD over a NONE source"           "SELECT LPAD(VN,10+0) X FROM S WHERE ID=1"
both "LPAD over a WIN1252 source"        "SELECT LPAD(VW,10+0) X FROM S WHERE ID=1"

# THE TEETH. Both sides agreeing is not enough: the multi-byte character
# must survive as UTF-8. 'straße' is 73 74 72 61 c3 9f - the bug shipped
# a bare df, which a diff of two identical bugs would never catch.
hex=$(printf 'SET HEADING OFF;\nSELECT SUBSTRING(V20 FROM 1 FOR 5+0) FROM S WHERE ID=1;\n' |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | od -An -tx1 | tr -d ' \n')
ran=$((ran + 1))
case "$hex" in
    *c39f*) echo "OK   teeth: the ß survives as UTF-8 c3 9f" ;;
    *df*)   echo "DIFF teeth: the ß came back as a bare df - the charset was lost"; fail=1 ;;
    *)      echo "DIFF teeth: no ß in the computed-length substring at all [$hex]"; fail=1 ;;
esac

echo "--- 2. UNION column reconciliation -----------------------------------"
both "a scaled branch beside an integer literal" \
    "SELECT CAST(1.50 AS NUMERIC(9,2)) AMT FROM RDB\$DATABASE UNION ALL SELECT 100 FROM RDB\$DATABASE"
both "an integer column beside a scaled one" \
    "SELECT II X FROM S WHERE ID=1 UNION ALL SELECT N92 FROM S WHERE ID=1"
both "UNION DISTINCT dedupes across the scales" \
    "SELECT N92 X FROM S WHERE ID=1 UNION SELECT 7 FROM RDB\$DATABASE"
both "the same-scale control, which never moved" \
    "SELECT N92 X FROM S WHERE ID=1 UNION ALL SELECT N92 FROM S WHERE ID=2"

# THE WIDTH LADDER. The widest branch wins on each axis independently,
# and the WIRE FORM has to move with the announced type - announcing a
# width the encoder does not write is how this first answered
# 6442450944.66 for 1.50, the 4-byte value landing in the high half of
# an 8-byte slot. Every rung, both orders where the order could matter.
both "SMALLINT beside INTEGER"     "SELECT SI X FROM S UNION ALL SELECT II FROM S ORDER BY 1"
both "INTEGER beside SMALLINT"     "SELECT II X FROM S UNION ALL SELECT SI FROM S ORDER BY 1"
both "INTEGER beside BIGINT"       "SELECT II X FROM S UNION ALL SELECT BI FROM S ORDER BY 1"
both "SMALLINT beside SMALLINT, the control" \
    "SELECT SI X FROM S UNION ALL SELECT SI FROM S ORDER BY 1"
both "a COLUMN beside an EXPRESSION over it" \
    "SELECT II X FROM S UNION ALL SELECT II+1 FROM S ORDER BY 1"
both "an expression that widens past its column" \
    "SELECT II X FROM S UNION ALL SELECT II*1000000000 FROM S ORDER BY 1"
both "NUMERIC(9,2) beside NUMERIC(15,4)" \
    "SELECT N92 X FROM S UNION ALL SELECT N154 FROM S ORDER BY 1"
both "... and the other way round"  \
    "SELECT N154 X FROM S UNION ALL SELECT N92 FROM S ORDER BY 1"
both "up to the 128-bit rung"      "SELECT N92 X FROM S UNION ALL SELECT I128 FROM S ORDER BY 1"
both "INTEGER beside NUMERIC(15,4)" "SELECT II X FROM S UNION ALL SELECT N154 FROM S ORDER BY 1"
# one approximate branch makes the WHOLE column a DOUBLE, and each
# exact branch's scaled integer has to become one (skipping that
# answered 0.0, since the encoder writes 0.0 for a value it cannot read
# as approximate)
both "an exact branch beside an approximate one" \
    "SELECT N92 X FROM S UNION ALL SELECT F FROM S ORDER BY 1"
both "... approximate FIRST"       "SELECT F X FROM S UNION ALL SELECT N92 FROM S ORDER BY 1"
both "an INTEGER beside a DOUBLE"  "SELECT II X FROM S UNION ALL SELECT F FROM S ORDER BY 1"
both "a fold over the widened union column" \
    "SELECT SUM(X) S FROM (SELECT N92 X FROM S UNION ALL SELECT N154 FROM S) Q"
# the boundary that remains: the engine reconciles a number beside TEXT
# by RENDERING the number, which needs the value side to render exactly
# as the engine does. Refused rather than guessed at.
refuses "a number beside TEXT" \
    "SELECT II X FROM S UNION ALL SELECT V20 FROM S"

# THE TEETH: the integer branch must render at the union's scale, not as
# its own raw digits under someone else's decimal point.
ran=$((ran + 1))
u=$(printf 'SET HEADING OFF;\nSELECT CAST(1.50 AS NUMERIC(9,2)) FROM RDB$DATABASE UNION ALL SELECT 100 FROM RDB$DATABASE;\n' |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | tr -s ' \n' ' ')
case "$u" in
    *100.00*) echo "OK   teeth: the integer branch reconciles to 100.00" ;;
    *) echo "DIFF teeth: the union answered [$u], not 100.00"; fail=1 ;;
esac

echo "--- 3. ORDER BY an output alias --------------------------------------"
# S.QTY descends as ID ascends, so an alias named QTY over ID orders the
# rows the OPPOSITE way from the base column: the two cannot be confused
# for one another by luck.
both "ORDER BY an alias that shadows a column" \
    "SELECT ID AS QTY FROM S ORDER BY QTY"
both "ORDER BY the shadowed base column, projected" \
    "SELECT QTY FROM S ORDER BY QTY"
both "ORDER BY an alias over an expression" \
    "SELECT ID*10 AS QTY FROM S ORDER BY QTY DESC"
both "ORDER BY the ordinal, which resolves to the projection" \
    "SELECT ID AS QTY FROM S ORDER BY 1 DESC"
both "an alias in the ORDER BY of a union branch" \
    "SELECT ID AS QTY FROM S UNION ALL SELECT ID FROM S ORDER BY 1"

# THE TEETH: the alias order must actually DIFFER from the base-column
# order, or the check above proves nothing.
ran=$((ran + 1))
byalias=$(printf 'SET HEADING OFF;\nSELECT ID AS QTY FROM S ORDER BY QTY;\n' |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | tr -s ' \n' ' ')
case "$byalias" in
    *"1 2 3"*) echo "OK   teeth: the alias sorts by the projected ID (1 2 3), not by QTY (3 2 1)" ;;
    *) echo "DIFF teeth: ORDER BY the alias gave [$byalias]"; fail=1 ;;
esac


echo "--- 4. the sub_type a FOLD carries ------------------------------------"
# Found by section 2 rather than by a probe: reconciling the union's
# sub_type left `SUM` over the reconciled column still announcing 0, and
# the same turned out to be true with no union in sight. A fold that
# KEEPS a value keeps its family - SUM/AVG/MIN/MAX over a NUMERIC are
# sub_type 1 and over a DECIMAL 2 - and MIN/MAX, which select an
# existing value rather than accumulating one, keep the column's own
# WIDTH too (a NUMERIC(9,2) stays a 4-byte LONG; this used to announce
# the fold's INT64). COUNT is the one fold with no source type at all.
both "SUM over a NUMERIC"              "SELECT SUM(N92) S FROM S"
both "AVG over a NUMERIC"              "SELECT AVG(N92) S FROM S"
both "MIN over a NUMERIC keeps its width" "SELECT MIN(N92) S FROM S"
both "MAX over a NUMERIC keeps its width" "SELECT MAX(N92) S FROM S"
both "SUM over a DECIMAL"              "SELECT SUM(D92) S FROM S"
both "MIN over a DECIMAL"              "SELECT MIN(D92) S FROM S"
both "SUM over a plain INTEGER, the control" "SELECT SUM(II) S FROM S"
both "MIN over a plain INTEGER, the control" "SELECT MIN(II) S FROM S"
both "the fold of an EXPRESSION source" "SELECT SUM(N92*2) S FROM S"
both "MIN of an expression source"     "SELECT MIN(N92+1) S FROM S"
both "a GROUPED fold"                  "SELECT SUM(N92) S FROM S GROUP BY ID ORDER BY 1"
both "a GROUPED MIN"                   "SELECT MIN(N92) S FROM S GROUP BY ID ORDER BY 1"
both "COUNT, which carries no source type" "SELECT COUNT(N92) S FROM S"
both "a fold inside an expression"     "SELECT SUM(N92)+1 S FROM S"
both "two folds of different families" "SELECT MIN(N92)+MAX(II) S FROM S"
both "a fold over the reconciled union column" \
    "SELECT SUM(X) S, COUNT(*) C FROM (SELECT N92 X FROM S WHERE ID=1 UNION ALL SELECT 5 FROM RDB\$DATABASE) Q"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 54 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
