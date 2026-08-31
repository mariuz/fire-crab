#!/bin/bash
# A SCALAR SUBQUERY ANSWERS UNDER ITS INNER COLUMN'S DESCRIPTION.
#
# `SELECT (SELECT <col> FROM T WHERE ...) FROM ...` is folded here by
# EXECUTING the subquery at plan time and splicing its value back into
# the statement as a literal. That fold is fine; what was not is that
# the describe was then taken from the LITERAL - that is, from the row
# that happened to be read. The inner plan was already being computed
# and thrown away unless it folded to a `Plan::Scalar`, which a
# plain-column subquery never does.
#
# Five symptoms from that one cause, all measured against the engine:
#
#  1. THE DESCRIBE DEPENDED ON THE DATA. `(SELECT <BIGINT>)` announced
#     LONG len 4 when the stored value was small and INT64 len 8 when it
#     was large. That is a protocol violation on its own - a client
#     caches what PREPARE told it - and it is the one law here that no
#     value comparison can catch, because both describes render the
#     right number. The check below asserts the two fire-crab describes
#     are identical TO EACH OTHER as well as to the engine.
#  2. A SMALLINT came back LONG.
#  3. A NUMERIC lost its scale and its family code (sub_type 0, widened
#     to INT64) - and so did the aggregate form, since the carrier type
#     had only three fields and could not express either.
#  4. A subquery matching NO ROWS described as TEXT(1) CHARACTER SET
#     NONE, because the literal spliced in was the word NULL.
#  5. TEXT lost its CHARACTER SET, and that corrupted the VALUE. Under a
#     NONE attachment a WIN1252 column shipped the UTF-8 spelling C3 A9
#     under a describe announcing CHARACTER SET NONE; the client
#     re-expanded those two bytes to C3 83 C2 A9 and rendered mojibake.
#     Probing this is what showed the fold itself is innocent: under a
#     UTF8 or WIN1252 attachment the BYTES were already correct and only
#     the padding width was wrong, so the value round trip through the
#     spliced literal is clean and the whole defect was the lost
#     description.
#
# The engine's law, probed and now implemented: the subquery describes
# EXACTLY as its inner column does. A CHAR(10) UTF8 stays 452 TEXT len
# 40 like the bare column, a VARCHAR stays 448 VARYING, OCTETS stays
# charset 1, a WIN1252 column keeps charset 53 under a NONE attachment
# and rescales to the attachment under UTF8 - the same rule a plain
# column already follows. Aggregates carry their source's scale AND
# sub_type: `(SELECT MAX(<NUMERIC(9,2)>) FROM T)` is LONG len 4 scale -2
# sub_type 1, and the DECIMAL twin is sub_type 2.
#
# Announcing the scale correctly is not cosmetic: `ProjCol::value_of`
# raises IntegerOverflow when a value's scale is FINER than the announced
# one, so a carrier that defaulted to scale 0 over a `Scaled(raw, -2)`
# would turn a working query into an error rather than a wrong number.
#
# ALSO FIXED HERE, found while testing the above: `SELECT NULL X` - a
# bare NULL with a bare (no-AS) alias - was refused. The alias splitter
# treats a trailing NULL in the head as the tail of an `IS NULL`, which
# must keep refusing; a head that IS exactly NULL is the literal. It
# surfaced through this construct because a no-row subquery with a bare
# alias folds to precisely `NULL X`.
#
#   qa/serve-real-subqdesc.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4341}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-subqdesc-a.fdb"   # fire-crab reads this one
B="$D/fc-subqdesc-b.fdb"   # the engine reads this one

mkdir -p "$D"
setup() { # <path>
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE T1 (ID INTEGER, SI SMALLINT, BI BIGINT, N92 NUMERIC(9,2), D92 DECIMAL(9,2),
                 CU CHAR(10), V20 VARCHAR(20),
                 W VARCHAR(10) CHARACTER SET WIN1252, O4 CHAR(4) CHARACTER SET OCTETS);
COMMIT;
INSERT INTO T1 VALUES (1, 11, 1111111111, 123.45, 123.45, 'abc', 'hello', 'ab', 'ABCD');
INSERT INTO T1 VALUES (2, 22, 9000000000000000000, 1.50, 1.50, 'xy', 'world', 'cd', 'WXYZ');
COMMIT;
UPDATE T1 SET W = _WIN1252 x'E9E0' WHERE ID = 1;
COMMIT;
/* T2 exists for the IN-EXPRESSION charset vectors and is deliberately
   separate from T1, whose rows several aggregate checks above depend on.
   W2's bytes 80 82 83 ... are NOT valid latin-1 characters, so a value
   that survived a latin-1 round trip cannot masquerade as correct here -
   which x'E9E0' (e-acute, a-grave) would. */
CREATE TABLE T2 (ID INTEGER, W2 VARCHAR(10) CHARACTER SET WIN1252,
                 U2 VARCHAR(10) CHARACTER SET UTF8,
                 N2 VARCHAR(10) CHARACTER SET NONE,
                 C2 CHAR(10) CHARACTER SET WIN1252);
COMMIT;
INSERT INTO T2 VALUES (1, x'8082838485868788898A', x'41C3A9425A', x'41E9425A', x'80828384');
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0
    while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-subqdesc.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0; ran=0
FC="127.0.0.1/$PORT:$A"
EN="127.0.0.1/3050:$B"

# describe line + values, one comparable string. `$3` is an optional
# attachment charset flag - resolve_text_cs answers differently per
# attachment, so every text law is checked under all three.
shape() { # <dsn> <select> [isql-flags]
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" ${3:-} "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype|^[A-Z0-9_]+ +' | od -An -c | tr -s ' \n' ' '
}
both() { # <label> <select> [flags]
    ran=$((ran + 1))
    e=$(shape "$EN" "$2" "${3:-}"); c=$(shape "$FC" "$2" "${3:-}")
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}
# just the describe, for the data-independence law
desc() { # <dsn> <select>
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE '^01: sqltype' | head -1 | tr -s ' '
}
hexval() { # <dsn> <select> [flags]
    printf 'SET HEADING OFF;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" ${3:-} "$1" 2>&1 |
        head -2 | od -An -tx1 | tr -s ' \n' ' '
}

echo "--- 1. the describe must not depend on the DATA -----------------------"
# BI holds 1111111111 at ID=1 and 9000000000000000000 at ID=2. Both
# describes must be INT64 - and, the part no value check can see, they
# must be identical TO EACH OTHER.
ran=$((ran + 1))
s1=$(desc "$FC" "SELECT (SELECT BI FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE")
s2=$(desc "$FC" "SELECT (SELECT BI FROM T1 WHERE ID = 2) AS X FROM RDB\$DATABASE")
s0=$(desc "$FC" "SELECT (SELECT BI FROM T1 WHERE ID = -1) AS X FROM RDB\$DATABASE")
if [ "$s1" = "$s2" ] && [ "$s1" = "$s0" ] && [ -n "$s1" ]; then
    echo "OK   the same statement describes identically over small, large and NO rows"
else
    echo "DIFF the describe moved with the data"
    echo "     small: $s1"; echo "     large: $s2"; echo "     none : $s0"; fail=1
fi
both "a small BIGINT"  "SELECT (SELECT BI FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE"
both "a large BIGINT"  "SELECT (SELECT BI FROM T1 WHERE ID = 2) AS X FROM RDB\$DATABASE"

echo "--- 2..4. the inner column's type, scale and family -------------------"
both "a SMALLINT"                "SELECT (SELECT SI FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE"
both "an INTEGER"                "SELECT (SELECT ID FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE"
both "a NUMERIC(9,2)"            "SELECT (SELECT N92 FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE"
both "a DECIMAL(9,2)"            "SELECT (SELECT D92 FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE"
both "no rows: a SMALLINT is still a SMALLINT" \
    "SELECT (SELECT SI FROM T1 WHERE ID = -1) AS X FROM RDB\$DATABASE"
both "no rows over a NUMERIC"    "SELECT (SELECT N92 FROM T1 WHERE ID = -1) AS X FROM RDB\$DATABASE"
both "no rows over text"         "SELECT (SELECT V20 FROM T1 WHERE ID = -1) AS X FROM RDB\$DATABASE"
both "MAX over a NUMERIC keeps scale and family" \
    "SELECT (SELECT MAX(N92) FROM T1) AS X FROM RDB\$DATABASE"
both "MAX over a DECIMAL"        "SELECT (SELECT MAX(D92) FROM T1) AS X FROM RDB\$DATABASE"
both "SUM, which widens"         "SELECT (SELECT SUM(N92) FROM T1) AS X FROM RDB\$DATABASE"
both "COUNT(*)"                  "SELECT (SELECT COUNT(*) FROM T1) AS X FROM RDB\$DATABASE"
both "COUNT with a WHERE"        "SELECT (SELECT COUNT(*) FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE"

echo "--- 5. the character set, per attachment ------------------------------"
for CH in "" "-ch UTF8" "-ch WIN1252"; do
    lbl="${CH:-(default NONE)}"
    both "a WIN1252 column $lbl"  "SELECT (SELECT W FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE" "$CH"
    both "a CHAR(10) UTF8 $lbl"   "SELECT (SELECT CU FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE" "$CH"
    both "a VARCHAR $lbl"         "SELECT (SELECT V20 FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE" "$CH"
    both "an OCTETS column $lbl"  "SELECT (SELECT O4 FROM T1 WHERE ID = 1) AS X FROM RDB\$DATABASE" "$CH"
done

# THE TEETH, and the reason this defect was worth a chunk: the WRAPPED
# read must ship the same bytes as the UNWRAPPED read of the same
# column, and as the engine. Comparing the two servers alone would not
# be enough - it is the wrapped-vs-unwrapped equality that localises the
# corruption to the wrapper.
for CH in "" "-ch UTF8" "-ch WIN1252"; do
    ran=$((ran + 1))
    w=$(hexval "$FC" "SELECT (SELECT W FROM T1 WHERE ID = 1) FROM RDB\$DATABASE" "$CH")
    u=$(hexval "$FC" "SELECT W FROM T1 WHERE ID = 1" "$CH")
    ew=$(hexval "$EN" "SELECT (SELECT W FROM T1 WHERE ID = 1) FROM RDB\$DATABASE" "$CH")
    if [ "$w" = "$ew" ] && [ "$w" = "$u" ] && [ -n "$w" ]; then
        echo "OK   teeth ${CH:-(default NONE)}: wrapped bytes == unwrapped == engine"
    else
        echo "DIFF teeth ${CH:-(default NONE)}"
        echo "     wrapped fc: $w"; echo "     unwrapped fc: $u"; echo "     engine: $ew"; fail=1
    fi
done

echo "--- 6. a bare NULL with a bare alias ----------------------------------"
both "SELECT NULL X"             "SELECT NULL X FROM RDB\$DATABASE"
both "SELECT NULL AS X, the control that worked" "SELECT NULL AS X FROM RDB\$DATABASE"
both "a no-row subquery with a BARE alias, which folds to NULL X" \
    "SELECT (SELECT SI FROM T1 WHERE ID = -1) X FROM RDB\$DATABASE"
both "IS NULL as a projected value keeps refusing on both" \
    "SELECT V20 X FROM T1 WHERE V20 IS NULL"
both "a bare alias over an expression, the control" "SELECT ID+1 X FROM T1 WHERE ID = 1"

echo "--- 7. the neighbours that must not move ------------------------------"
both "a CORRELATED subquery, which takes another path" \
    "SELECT ID, (SELECT MAX(N92) FROM T1 I WHERE I.ID = O.ID) AS M FROM T1 O ORDER BY ID"
both "EXISTS, which keeps its own BOOL payload" \
    "SELECT EXISTS(SELECT 1 FROM T1) AS X FROM RDB\$DATABASE"
both "a subquery INSIDE an expression takes the expression's rules" \
    "SELECT (SELECT SI FROM T1 WHERE ID = 1) + 1 AS X FROM RDB\$DATABASE"
both "a subquery in a WHERE clause"  "SELECT ID FROM T1 WHERE ID = (SELECT MIN(ID) FROM T1)"
both "a plain column, unwrapped"     "SELECT W AS X FROM T1 WHERE ID = 1"

echo "--- 7. a subquery that is an OPERAND keeps its column's charset -------"
# The fold splices the subquery's VALUE back into the statement text, so
# without care the spliced literal is typed like any other literal - in
# the ATTACHMENT's character set - and the inner column's set is lost the
# moment the subquery becomes an operand of anything. The bare form was
# already repaired by the describe patch pass, which only fires when the
# marker IS the whole select item; these are the shapes that pass had no
# reach over. Every one runs under all three attachments, because the
# defect's signature was that the ANSWER MOVED with -ch while the
# engine's stayed put.
for CH in "" "-ch UTF8" "-ch WIN1252"; do
    l="${CH:--ch NONE}"
    both "OCTET_LENGTH over a WIN1252 subquery $l" \
        "SELECT OCTET_LENGTH((SELECT W2 FROM T2 WHERE ID=1)) AS X FROM RDB\$DATABASE" "$CH"
    both "OCTET_LENGTH over a UTF8 subquery $l" \
        "SELECT OCTET_LENGTH((SELECT U2 FROM T2 WHERE ID=1)) AS X FROM RDB\$DATABASE" "$CH"
    both "CHAR_LENGTH over a WIN1252 subquery $l" \
        "SELECT CHAR_LENGTH((SELECT W2 FROM T2 WHERE ID=1)) AS X FROM RDB\$DATABASE" "$CH"
    both "the subquery CAST to its own set $l" \
        "SELECT CAST(CAST((SELECT W2 FROM T2 WHERE ID=1) AS VARCHAR(10) CHARACTER SET WIN1252) AS VARCHAR(40) CHARACTER SET OCTETS) AS X FROM RDB\$DATABASE" "$CH"
    both "the subquery concatenated $l" \
        "SELECT CAST((SELECT W2 FROM T2 WHERE ID=1) || '!' AS VARCHAR(40) CHARACTER SET OCTETS) AS X FROM RDB\$DATABASE" "$CH"
    both "the concatenation's DESCRIBE $l" \
        "SELECT (SELECT W2 FROM T2 WHERE ID=1) || '!' AS X FROM RDB\$DATABASE" "$CH"
    both "TRIM over a subquery $l" \
        "SELECT CAST(TRIM((SELECT U2 FROM T2 WHERE ID=1)) AS VARCHAR(40) CHARACTER SET OCTETS) AS X FROM RDB\$DATABASE" "$CH"
    both "a CHAR subquery pads in ITS OWN characters $l" \
        "SELECT CAST(CAST((SELECT C2 FROM T2 WHERE ID=1) AS CHAR(10) CHARACTER SET WIN1252) AS VARCHAR(60) CHARACTER SET OCTETS) AS X FROM RDB\$DATABASE" "$CH"
    both "a NONE subquery as an operand $l" \
        "SELECT OCTET_LENGTH((SELECT N2 FROM T2 WHERE ID=1)) AS X FROM RDB\$DATABASE" "$CH"
    # controls: the same expressions over the COLUMN, which must agree
    # whatever happens to subqueries
    both "control, the column not a subquery $l" \
        "SELECT OCTET_LENGTH(W2), CHAR_LENGTH(W2) FROM T2 WHERE ID=1" "$CH"
done

echo "----------------------------------------------------------------------"
[ "$ran" -ge 68 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
