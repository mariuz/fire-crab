#!/bin/bash
# WHEN SEVERAL BRANCHES ANSWER UNDER ONE DESCRIPTION.
#
# A UNION describes one column per position and decodes every branch's
# value under it. So does a CASE, a COALESCE, an IIF, a DECODE and the
# anchor/recursive pair of a recursive CTE. The law is the same in all
# of them and it has two halves that must agree:
#
#   1. the description is RECONCILED from every branch, and
#   2. every branch's VALUE is then brought to that description.
#
# fire-crab had the first half and not the second, which is the worst
# possible split: the describe looks right, a row comes back, and the
# number in it is wrong. The flagship:
#
#   SELECT SUM(CASE WHEN <false> THEN CAST(1.50 AS NUMERIC(9,2))
#                   ELSE 100 END) FROM T
#   engine 200.00        fire-crab 2.00
#
# The integer branch answered a raw 100 where the announced scale of -2
# wanted 10000, so every row contributed 1.00 instead of 100.00.
# `SUM(CASE WHEN ... THEN <amount> ELSE 0 END)` is a workhorse idiom and
# it was returning money short by a factor of 100.
#
# WHAT MADE IT HIDE, and why this gate compares the describe and the
# value TOGETHER: the DIRECT projection of that same conditional is
# CORRECT on both servers, because the encoder renders the value's own
# scale. The defect appears only once something CONSUMES the datum - an
# aggregate, or a CAST to text. A value-only check of the expression
# itself sees nothing wrong.
#
# The rest of the family, each measured against the engine:
#   - a conditional's SUB_TYPE is the MAX family code of its branches
#     (0 plain / 1 NUMERIC / 2 DECIMAL). CASE had no rule at all and
#     announced 0 for every one.
#   - NULLIF takes its sub_type from the FIRST operand alone: its value
#     IS that operand, the second only decides whether it is NULL.
#   - MIN/MAX DESCRIBE WHAT THEIR SOURCE DESCRIBES, expression sources
#     included. Reading `MAX(ID+0)` is INT64 as "an expression source
#     stays the fold's INT64" was the wrong lesson - `ID+0` is itself
#     INT64, the arithmetic having widened it before the fold saw it,
#     while `MAX(CASE ... <INTEGER> ... END)` is a 4-byte LONG.
#   - an 8-byte NUMERIC RANKS as I64: that is what makes SUM widen it to
#     INT128 and a multiplication around it promote. Everything below 16
#     bytes ranked as a 4-byte LONG, so neither promotion fired.
#   - a UNION of TEXT branches takes the WIDEST length, VARYING wins
#     over the fixed form, and the charset follows the concatenation
#     join. The width is maxed in CHARACTERS, not in the branches' own
#     units: a plain column carries its width in the bytes of ITS OWN
#     charset, so a WIN1252 VARCHAR(6) is 6 and a UTF8 one is 24.
#
# TWO RECORDED DIVERGENCES, both asserted here so they cannot rot:
#   - a recursive CTE whose recursive member answers at a DIFFERENT
#     SCALE from the anchor REFUSES. The engine keeps the recursion in
#     full precision and only renders at the anchor's description
#     (`SELECT 1 UNION ALL SELECT X + 0.5` answers 1, 2, 2, 3, 3 - the
#     values 1, 1.5, 2.0, 2.5, 3.0 each rounded at output), which needs
#     two column sets this planner does not carry. Before, it answered
#     **15** - the raw of 1.5 read as a scale-0 integer - and 15 then
#     failed the loop guard, truncating the result set too. A refusal is
#     the honest answer until the two-column-set version exists.
#   - a SIMPLE CASE (`CASE x WHEN ...`) and DECODE are announced NOT
#     NULL where the engine says Nullable, even with an ELSE. Both
#     lower to the same node as a searched CASE, so telling them apart
#     needs a flag on it. VALUES are identical; this is the describe's
#     nullable bit alone. NOT asserted below - it is a KNOWN divergence,
#     recorded in docs/roadmap.md.
#
#   qa/serve-real-branchtype.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4337}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-branchtype-a.fdb"   # fire-crab reads this one
B="$D/fc-branchtype-b.fdb"   # the engine reads this one

# TWIN databases, and both servers reached over TCP - a bare file path
# would attach the EMBEDDED engine and change more than the server under
# test. The drop-then-unlink is because a previous run's rm can land
# while the engine is still closing its own attachment, and the next
# CREATE DATABASE then fails on a file that is gone from the directory
# but not yet from the engine.
mkdir -p "$D"
setup() { # <path>
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER, N92 NUMERIC(9,2), N154 NUMERIC(15,4), D92 DECIMAL(9,2),
                C5 CHAR(5), V3 VARCHAR(3), V10 VARCHAR(10),
                W6 VARCHAR(6) CHARACTER SET WIN1252,
                U6 VARCHAR(6) CHARACTER SET UTF8,
                N6 VARCHAR(6) CHARACTER SET NONE);
COMMIT;
INSERT INTO T VALUES (1, 1.50, 2.5000, 3.25, 'ab', 'xy', 'hello', 'ab', 'cd', 'ef');
INSERT INTO T VALUES (2, 10.50, 3.5000, 4.75, 'cd', 'zw', 'world', 'gh', 'ij', 'kl');
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0
    while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-branchtype.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "SOMETHING is listening" is not "OUR server is listening": if the port
# was taken, fcwire died at bind and every check would run against the
# other server and pass while measuring nothing.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0; ran=0
FC="127.0.0.1/$PORT:$A"
EN="127.0.0.1/3050:$B"

# the describe line AND the rendered values, as one comparable string
shape() { # <dsn> <select>
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype|^[A-Z0-9_]+ +' | od -An -c | tr -s ' \n' ' '
}
both() { # <label> <select>
    ran=$((ran + 1))
    e=$(shape "$EN" "$2"); c=$(shape "$FC" "$2")
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}
# a shape fire-crab must REFUSE rather than answer wrongly; the engine
# ANSWERING is asserted too, so this cannot pass by both sides failing
refuses() { # <label> <select>
    ran=$((ran + 1))
    c=$(printf 'SET LIST ON;\n%s;\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1)
    e=$(printf 'SET LIST ON;\n%s;\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$EN" 2>&1)
    case "$e" in *"Statement failed"*) echo "DIFF $1: the ENGINE refused too, the check is vacuous"; fail=1; return ;; esac
    case "$c" in
        *"Statement failed"*) echo "OK   refused (recorded boundary): $1" ;;
        *) echo "DIFF $1 ANSWERED where it cannot reconcile: $(printf '%s' "$c" | tr -s ' \n' ' ')"; fail=1 ;;
    esac
}

echo "--- 1. a conditional must ANSWER at the scale it announces ------------"
both "SUM over a CASE with an integer branch" \
    "SELECT SUM(CASE WHEN 1=0 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE 100 END) X FROM T"
both "AVG over the same" \
    "SELECT AVG(CASE WHEN 1=0 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE 100 END) X FROM T"
both "SUM over COALESCE" \
    "SELECT SUM(COALESCE(CAST(NULL AS NUMERIC(9,2)), 100)) X FROM T"
both "SUM over IIF"  "SELECT SUM(IIF(1=0, CAST(1.50 AS NUMERIC(9,2)), 100)) X FROM T"
both "SUM over DECODE" "SELECT SUM(DECODE(1, 2, CAST(1.50 AS NUMERIC(9,2)), 100)) X FROM T"
both "the idiom itself: SUM(CASE .. THEN amount ELSE 0)" \
    "SELECT SUM(CASE WHEN ID=1 THEN N92 ELSE 0 END) X FROM T"
both "a wider scale, where the factor is 10^4" \
    "SELECT SUM(CASE WHEN 1=0 THEN N154 ELSE 100 END) X FROM T"
both "CAST to text, which reads the raw number" \
    "SELECT CAST(CASE WHEN 1=0 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE 100 END AS VARCHAR(20)) X FROM RDB\$DATABASE"
both "CAST to text through COALESCE" \
    "SELECT CAST(COALESCE(CAST(NULL AS NUMERIC(9,2)), 100) AS VARCHAR(20)) X FROM RDB\$DATABASE"
both "grouped, one group per row" \
    "SELECT SUM(CASE WHEN 1=0 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE 100 END) X FROM T GROUP BY ID ORDER BY 1"
# the CONTROL that hid it: the direct projection was always right
both "the direct projection, which never moved" \
    "SELECT CASE WHEN 1=0 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE 100 END X FROM RDB\$DATABASE"
both "an all-integer conditional, nothing to align" \
    "SELECT SUM(CASE WHEN ID=1 THEN 1 ELSE 0 END) X FROM T"

# THE TEETH: 200.00, not 2.00. Both sides agreeing is not enough - the
# factor of 100 is the whole finding.
ran=$((ran + 1))
v=$(printf 'SET HEADING OFF;\nSELECT SUM(CASE WHEN 1=0 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE 100 END) FROM T;\n' |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | tr -s ' \n' ' ')
case "$v" in
    *200.00*) echo "OK   teeth: the folded conditional answers 200.00" ;;
    *) echo "DIFF teeth: the fold answered [$v], not 200.00"; fail=1 ;;
esac

echo "--- 2. the sub_type a conditional carries ----------------------------"
both "CASE over two NUMERICs"  "SELECT CASE WHEN 1=1 THEN CAST(1.50 AS NUMERIC(9,2)) ELSE CAST(2.50 AS NUMERIC(9,2)) END X FROM RDB\$DATABASE"
both "CASE over a DECIMAL"     "SELECT CASE WHEN 1=1 THEN D92 ELSE N92 END X FROM T WHERE ID=1"
both "CASE mixing a column and a literal" \
    "SELECT CASE WHEN 1=0 THEN D92 ELSE 100 END X FROM T WHERE ID=1"
both "COALESCE, which had the rule already" "SELECT COALESCE(N92, 0) X FROM T WHERE ID=1"
both "NULLIF takes its FIRST operand's family" \
    "SELECT NULLIF(ID, CAST(2.5 AS DECIMAL(9,2))) X FROM T WHERE ID=1"
both "NULLIF over two NUMERICs" "SELECT NULLIF(N92, D92) X FROM T WHERE ID=1"

echo "--- 3. MIN/MAX describe what their SOURCE describes -------------------"
both "MAX over a CASE of NUMERIC(9,2)"  "SELECT MAX(CASE WHEN ID=1 THEN N92 ELSE N92 END) X FROM T"
both "MAX over a CASE of NUMERIC(15,4)" "SELECT MAX(CASE WHEN ID=1 THEN N154 ELSE N154 END) X FROM T"
both "MAX over a CASE of INTEGERs"      "SELECT MAX(CASE WHEN ID=1 THEN ID ELSE ID END) X FROM T"
both "MAX over an arithmetic expression, which widened first" \
    "SELECT MAX(ID+0) X FROM T"
both "MAX over a widened numeric expression" "SELECT MAX(N92+0) X FROM T"
both "MIN over COALESCE"                "SELECT MIN(COALESCE(N92,0)) X FROM T"
both "MAX over a plain column, the control" "SELECT MAX(N92) X FROM T"
both "MIN over a column, grouped"       "SELECT MIN(N92) X FROM T GROUP BY ID ORDER BY 1"
both "MAX over IIF of two widths"       "SELECT MAX(IIF(ID=1,N92,N154)) X FROM T"

echo "--- 4. an 8-byte NUMERIC ranks I64 -----------------------------------"
both "SUM widens a NUMERIC(18,4) to INT128" "SELECT SUM(CAST(1.5 AS NUMERIC(18,4))) X FROM T"
both "... and leaves NUMERIC(9,2) at INT64" "SELECT SUM(CAST(1.5 AS NUMERIC(9,2))) X FROM T"
both "multiplication promotes around it"    "SELECT CAST(1.5 AS NUMERIC(18,4)) * CAST(2 AS NUMERIC(18,4)) X FROM RDB\$DATABASE"
both "... and does not below it"            "SELECT CAST(1.5 AS NUMERIC(9,2)) * CAST(2 AS NUMERIC(9,2)) X FROM RDB\$DATABASE"
both "the bare cast, which never widened"   "SELECT CAST(1.5 AS NUMERIC(18,4)) X FROM RDB\$DATABASE"

echo "--- 5. a UNION of TEXT branches ---------------------------------------"
both "two literals of unequal length"  "SELECT 'a' S FROM RDB\$DATABASE UNION ALL SELECT 'bb' FROM RDB\$DATABASE"
both "... and the other way round"     "SELECT 'bb' S FROM RDB\$DATABASE UNION ALL SELECT 'a' FROM RDB\$DATABASE"
both "two VARCHARs of unequal length"  "SELECT V3 S FROM T WHERE ID=1 UNION ALL SELECT V10 FROM T WHERE ID=1"
both "a CHAR beside a VARCHAR"         "SELECT C5 S FROM T WHERE ID=1 UNION ALL SELECT V10 FROM T WHERE ID=1"
both "a CHAR beside a literal"         "SELECT C5 S FROM T WHERE ID=1 UNION ALL SELECT 'zz' FROM RDB\$DATABASE"
both "equal widths, the control"       "SELECT V3 S FROM T WHERE ID=1 UNION ALL SELECT V3 FROM T WHERE ID=1"
both "a real charset beats the literal's sentinel" \
    "SELECT U6 S FROM T WHERE ID=1 UNION ALL SELECT 'zz' FROM RDB\$DATABASE"
both "... whichever side it is on"     "SELECT 'zz' S FROM RDB\$DATABASE UNION ALL SELECT U6 FROM T WHERE ID=1"
both "of two real charsets the FIRST wins" \
    "SELECT W6 S FROM T WHERE ID=1 UNION ALL SELECT U6 FROM T WHERE ID=1"
both "... and the width follows the winner" \
    "SELECT U6 S FROM T WHERE ID=1 UNION ALL SELECT W6 FROM T WHERE ID=1"
both "NONE yields to a real charset"   "SELECT N6 S FROM T WHERE ID=1 UNION ALL SELECT U6 FROM T WHERE ID=1"
both "... in either order"             "SELECT U6 S FROM T WHERE ID=1 UNION ALL SELECT N6 FROM T WHERE ID=1"
both "a DISTINCT union of unequal literals" \
    "SELECT 'a' S FROM RDB\$DATABASE UNION SELECT 'bb' FROM RDB\$DATABASE"

# THE TEETH: the short value must come back PADDED, not truncate the
# cursor. This died mid-fetch with a 22001 before.
ran=$((ran + 1))
t=$(printf 'SET HEADING OFF;\nSELECT 1 K, %s FROM RDB$DATABASE UNION ALL SELECT 2, %s FROM RDB$DATABASE;\n' "'a'" "'bb'" |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | tr -s ' \n' ' ')
case "$t" in
    *truncation*) echo "DIFF teeth: the second row still truncates [$t]"; fail=1 ;;
    *bb*) echo "OK   teeth: both rows of the widened union come back" ;;
    *) echo "DIFF teeth: the union answered [$t]"; fail=1 ;;
esac

echo "--- 6. the recursive CTE ---------------------------------------------"
both "the ordinary integer generator" \
    "WITH RECURSIVE N AS (SELECT 1 X FROM RDB\$DATABASE UNION ALL SELECT X + 1 FROM N WHERE X < 5) SELECT * FROM N"
both "a doubling walk"  \
    "WITH RECURSIVE N AS (SELECT 1 X FROM RDB\$DATABASE UNION ALL SELECT X * 2 FROM N WHERE X < 20) SELECT * FROM N"
both "a BIGINT anchor"  \
    "WITH RECURSIVE N AS (SELECT CAST(1 AS BIGINT) X FROM RDB\$DATABASE UNION ALL SELECT X + 1 FROM N WHERE X < 4) SELECT * FROM N"
# the boundary: a recursive member at a DIFFERENT SCALE from the anchor
refuses "a recursive member that changes the column's scale" \
    "WITH RECURSIVE N AS (SELECT 1 X FROM RDB\$DATABASE UNION ALL SELECT X + 0.5 FROM N WHERE X < 3) SELECT * FROM N"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 46 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
