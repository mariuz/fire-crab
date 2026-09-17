#!/bin/bash
# AN INPUT PARAMETER IS DESCRIBED IN THE ATTACHMENT'S CHARACTER SET.
#
# The output side of this law has been implemented since 2026-08-21
# (`resolve_text_cs`): a text COLUMN of a real charset is announced in
# the attachment's set, its character count preserved and its byte width
# rescaled. The INPUT side was never wired - `append_bind_section` and
# `answer_prepare`'s bind vars both built their slots straight from the
# descriptor - so every `?` was announced in its DESTINATION's charset
# whatever the client had attached as.
#
# THE LAW, measured slot by slot against the live engine:
#
#   * a `?` whose destination is a REAL charset is announced in the
#     ATTACHMENT's set - VARCHAR(5) WIN1252 under UTF8 is len 20 cs 4,
#     VARCHAR(5) UTF8 under WIN1252 is len 5 cs 53, CHAR(5) UTF8 the
#     same; the CHARACTER count is what survives, not the byte width;
#   * the BYTE CARRIERS are the exception: a NONE or an OCTETS
#     destination is never transliterated, on any attachment;
#   * but ASCII IS transliterated (len 20 cs 4 under UTF8), which is why
#     this cannot be written with `intl::byte_carrier` - that counts
#     ASCII as a carrier and would leave this cell wrong;
#   * the attachment overrides even an EXPLICIT charset: `CAST(? AS
#     VARCHAR(5) CHARACTER SET UTF8)` under WIN1252 is len 5 cs 53;
#   * and a cast that names NO set takes the attachment's rather than
#     NONE - which is why a cast slot cannot simply carry `0`: a bare 0
#     is indistinguishable from a genuine NONE COLUMN, and those two
#     resolve DIFFERENTLY.
#
# HOW IT IS SEEN. isql cannot EXECUTE a statement with parameters, but
# `SET SQLDA_DISPLAY ON` prints the INPUT message it prepared, and `SET
# PLANONLY ON` stops it trying to run the statement at all - so an
# INSERT's slots can be read without inserting anything. Only the lines
# between `INPUT message` and `OUTPUT message` are compared: the output
# half is other gates' business and would fail these cells for reasons
# that have nothing to do with the bind section.
#
# THREE ATTACHMENTS, ALWAYS - the rule serve-real-litcs records. Under a
# NONE attachment fire-crab already agreed on every cell here, so a gate
# that ran isql's default alone would score the entire divergence class
# as green.
#
#   qa/serve-real-bindcs.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4319}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-bindcs-work.fdb"   # fire-crab serves this one
REF="$D/fc-bindcs-ref.fdb"     # the engine serves this one

mkdir -p "$D"; rm -f "$WORK" "$REF"
fail=0; ran=0

make_db() {
    rm -f "$1"
    # created EMBEDDED then chmod 666 - the house idiom: a database
    # created over TCP belongs to the ENGINE's user and fire-crab cannot
    # then write it
    "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 <<EOF || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET NONE;
CREATE TABLE T (U VARCHAR(5) CHARACTER SET UTF8,
                W VARCHAR(5) CHARACTER SET WIN1252,
                N VARCHAR(5) CHARACTER SET NONE,
                O VARCHAR(5) CHARACTER SET OCTETS,
                A VARCHAR(5) CHARACTER SET ASCII,
                C CHAR(5) CHARACTER SET UTF8,
                I INTEGER, S SMALLINT, B BIGINT, NN INTEGER NOT NULL);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$WORK" || { echo "FAIL scratch WORK"; exit 1; }
make_db "$REF"  || { echo "FAIL scratch REF"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-bindcs-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
i=0; while [ $i -lt 20 ]; do
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "SOMETHING is listening" is not "OUR server is listening"
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# The INPUT message's slots, and nothing else.
slots() { # <connstring> <charset> <sql>
    printf 'SET SQLDA_DISPLAY ON;\nSET PLANONLY ON;\n%s\n' "$3" |
        timeout 40 "$ISQL" -q -b -ch "$2" -user "$U" -pas "$P" "$1" 2>&1 |
        awk '/INPUT message/{i=1; next} /OUTPUT message/{i=0} i && /sqltype/{print}' |
        tr -s ' ' | sed 's/^ //; s/ $//' | paste -sd'|'
}

# every statement under all three attachments
cell() { # <label> <sql> [charsets...]
    local lbl="$1" sql="$2"; shift 2
    local chs="${*:-NONE UTF8 WIN1252}"
    local ch e f
    for ch in $chs; do
        ran=$((ran + 1))
        e=$(slots "127.0.0.1/$REAL:$REF" "$ch" "$sql")
        f=$(slots "127.0.0.1/$PORT:$WORK" "$ch" "$sql")
        if [ -z "$e" ] || [ -z "$f" ]; then
            echo "DIFF [-ch $ch] $lbl described NO input slot (engine=[$e] fc=[$f])"
            fail=1; continue
        fi
        if [ "$e" = "$f" ]; then
            # printed on success too: a run that agrees for the wrong
            # reason stays visible in the log
            echo "OK   [-ch $ch] $lbl: $e"
        else
            echo "DIFF [-ch $ch] $lbl"
            echo "     engine: [$e]"
            echo "     fc:     [$f]"
            fail=1
        fi
    done
}

# THE POSITIVE CONTROL, and this gate needs a sharp one: every cell
# compares two servers, so a probe that described nothing would make
# both agree on empty. Assert that the ENGINE ITSELF moves a slot when
# the attachment changes - if this stops being true the whole gate is
# measuring nothing, whatever the cells say.
ran=$((ran + 1))
c_none=$(slots "127.0.0.1/$REAL:$REF" NONE    "INSERT INTO T (W) VALUES (?);")
c_utf8=$(slots "127.0.0.1/$REAL:$REF" UTF8    "INSERT INTO T (W) VALUES (?);")
case "$c_none|$c_utf8" in
    *"charset: 53"*"charset: 4"*)
        echo "OK   control: the ENGINE moves a WIN1252 slot to UTF8 with the attachment" ;;
    *)
        echo "DIFF control: the engine did not transliterate the slot"
        echo "     NONE: [$c_none]"; echo "     UTF8: [$c_utf8]"; fail=1 ;;
esac

echo "-- a destination of a REAL charset takes the attachment's --"
cell "a UTF8 column"                 "INSERT INTO T (U) VALUES (?);"
cell "a WIN1252 column"              "INSERT INTO T (W) VALUES (?);"
cell "an ASCII column IS transliterated" "INSERT INTO T (A) VALUES (?);"
cell "a CHAR, which keeps its 452"   "INSERT INTO T (C) VALUES (?);"
cell "a comparison slot, not just an assignment" "SELECT 1 FROM T WHERE U = ?;"

echo "-- ...and a BYTE CARRIER never is --"
cell "a NONE column"                 "INSERT INTO T (N) VALUES (?);"
cell "an OCTETS column"              "INSERT INTO T (O) VALUES (?);"
cell "a NONE comparison slot"        "SELECT 1 FROM T WHERE N = ?;"

echo "-- a CAST target: the attachment beats even an EXPLICIT charset --"
cell "CAST with no charset named"    "SELECT CAST(? AS VARCHAR(5)) FROM RDB\$DATABASE;"
cell "CAST naming UTF8 explicitly"   "SELECT CAST(? AS VARCHAR(5) CHARACTER SET UTF8) FROM RDB\$DATABASE;"
cell "CAST AS CHAR, naming none"     "SELECT CAST(? AS CHAR(5)) FROM RDB\$DATABASE;"

# A `?` TAKES THE OTHER SIDE'S OWN DESCRIPTOR.
#
# Recorded here and not fixed for one commit, then measured out in full.
# A slot compared against an EXPRESSION is announced as that expression:
# its type, its CHARACTER width in the charset the expression resolves
# to, and - when the expression reads no column - NOT NULL.
#
# The three axes, each its own defect and each measured:
#
#   TYPE    `? = 1` is a LONG, not a BIGINT; past INTEGER range it IS a
#           BIGINT (`? = 5000000000`). A text literal is 452 TEXT; a
#           computed text expression (`||`, UPPER of a column) is 448.
#   WIDTH   the literal's own character count, scaled to the announced
#           charset: `? > 'abc'` is 3 bytes NONE, 12 UTF8, 3 WIN1252.
#   NULL    a slot typed by an expression that reads NO COLUMN is NOT
#           NULL (`? = 1 + 1`, `? = UPPER('abc')`); one that reads a
#           column keeps that column's nullability.
#
# The last is the one no row-comparison gate could ever catch, and the
# one that differs on EVERY attachment including NONE.
echo "-- a ? takes the other side's TYPE and WIDTH --"
cell "= a 1-char literal"            "SELECT 1 FROM RDB\$DATABASE WHERE ? = 'x';"
cell "= a 5-char literal"            "SELECT 1 FROM RDB\$DATABASE WHERE ? = 'abcde';"
cell "the literal on the LEFT"       "SELECT 1 FROM RDB\$DATABASE WHERE 'x' = ?;"
cell "a non-equality comparison"     "SELECT 1 FROM RDB\$DATABASE WHERE ? > 'abc';"
cell "BETWEEN takes the LOW bound"   "SELECT 1 FROM RDB\$DATABASE WHERE ? BETWEEN 'a' AND 'bbb';"
cell "IN takes the WIDEST element"   "SELECT 1 FROM RDB\$DATABASE WHERE ? IN ('a','bb');"
# ...and the SAME list REORDERED, which is the cell that has teeth: with
# the widest element FIRST, a server that simply keeps the last one it
# saw answers 1 where the engine answers 2. The passing cell above has
# its widest element last and cannot tell the two apart - it was a
# passenger until these joined it.
cell "IN, widest element FIRST"      "SELECT 1 FROM RDB\$DATABASE WHERE ? IN ('bb','a');"
cell "IN, widest element in the MIDDLE" "SELECT 1 FROM RDB\$DATABASE WHERE ? IN ('a','bbb','cc');"
cell "STARTING WITH types from the prefix" "SELECT 1 FROM RDB\$DATABASE WHERE ? STARTING WITH 'ab';"
cell "IN, the widest of four"         "SELECT 1 FROM RDB\$DATABASE WHERE ? IN ('a','bbbb','cc','d');"
cell "BETWEEN, equal-width bounds"    "SELECT 1 FROM RDB\$DATABASE WHERE ? BETWEEN 'aa' AND 'bb';"

# THE SAME TWO RULES IN THE NUMERIC FAMILY, which is where they are
# easiest to tell apart - and where assuming BETWEEN took the WIDER
# bound (as IN takes the wider element) would be wrong in BOTH
# directions. These run under ONE attachment: an INT64 slot has no
# charset, so running them under three would triple the cost for no
# information.
echo "-- ...and the same two rules over NUMERIC lists --"
cell "BETWEEN low=NARROW decides"     "SELECT 1 FROM RDB\$DATABASE WHERE ? BETWEEN 1 AND 5000000000;" NONE
cell "BETWEEN low=WIDE decides"       "SELECT 1 FROM RDB\$DATABASE WHERE ? BETWEEN 5000000000 AND 1;" NONE
cell "BETWEEN low drops the scale"    "SELECT 1 FROM RDB\$DATABASE WHERE ? BETWEEN 1 AND 2.5;" NONE
cell "BETWEEN low KEEPS the scale"    "SELECT 1 FROM RDB\$DATABASE WHERE ? BETWEEN 2.5 AND 1;" NONE
cell "IN, the wide one LAST"          "SELECT 1 FROM RDB\$DATABASE WHERE ? IN (1, 5000000000);" NONE
cell "IN, the wide one FIRST"         "SELECT 1 FROM RDB\$DATABASE WHERE ? IN (5000000000, 1);" NONE
cell "IN, both narrow"                "SELECT 1 FROM RDB\$DATABASE WHERE ? IN (1, 2);" NONE
cell "IN, a scaled item outranks"     "SELECT 1 FROM RDB\$DATABASE WHERE ? IN (1, 2.5);" NONE
cell "a LIKE pattern is VARYING"     "SELECT 1 FROM RDB\$DATABASE WHERE ? LIKE 'a%';"
cell "an integer literal is a LONG"  "SELECT 1 FROM RDB\$DATABASE WHERE ? = 1;"
cell "...and past INTEGER, a BIGINT" "SELECT 1 FROM RDB\$DATABASE WHERE ? = 5000000000;"
cell "a scaled literal keeps scale"  "SELECT 1 FROM RDB\$DATABASE WHERE ? = 1.5;"
cell "a DATE literal"                "SELECT 1 FROM RDB\$DATABASE WHERE ? = DATE '2020-01-01';"

echo "-- ...and NOT NULL exactly when the side reads no column --"
cell "folded literals are NOT NULL"  "SELECT 1 FROM RDB\$DATABASE WHERE ? = 1 + 1;"
cell "a CAST of a literal, NOT NULL" "SELECT 1 FROM RDB\$DATABASE WHERE ? = CAST('x' AS CHAR(3));"
cell "a VARCHAR cast is 448"         "SELECT 1 FROM RDB\$DATABASE WHERE ? = CAST('x' AS VARCHAR(3));"
cell "a function OF a literal"       "SELECT 1 FROM RDB\$DATABASE WHERE ? = UPPER('abc');"
cell "an expression OVER a column stays nullable" "SELECT 1 FROM T WHERE ? = I + 1;"
cell "a text expression over a column" "SELECT 1 FROM T WHERE ? = U || 'x';"
cell "UPPER of a column"             "SELECT 1 FROM T WHERE ? = UPPER(U);"

# THE CONTROLS. A bare column on the other side has taken the column's
# own descriptor since long before this slice, and must keep doing so -
# these pass on BOTH binaries, which is what separates a control from a
# passenger.
echo "-- controls: a bare COLUMN side, unchanged by this slice --"
cell "a SMALLINT column"             "SELECT 1 FROM T WHERE ? = S;"
cell "a BIGINT column"               "SELECT 1 FROM T WHERE ? = B;"
cell "a nullable INTEGER column"     "SELECT 1 FROM T WHERE ? = I;"
cell "a NOT NULL column"             "SELECT 1 FROM T WHERE ? = NN;"

# RECORDED, NOT FIXED - measured beside the cells above:
#
#   `? CONTAINING 'abc'` describes on the engine as 448 VARYING at the
#   pattern's character width (3 bytes NONE), NOT NULL - and fire-crab
#   REFUSES the statement outright, describing nothing at all. That is a
#   missing predicate shape, not a describe defect: `? LIKE` and `?
#   STARTING WITH` resolve here and CONTAINING has no tested-side arm.
#   It is left for a slice of its own rather than grown into this one.
#
#   `? LIKE ?` (a parameter PATTERN) describes both slots as the fixed
#   30 on both servers, and its charset and nullability were never
#   probed - so those two slots keep their flat descriptor deliberately.

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$WORK" "$REF"
[ "$ran" -ge 123 ] || { echo "FAIL only $ran checks ran (expected >= 123)"; fail=1; }
[ $fail = 0 ] && echo "PASS bindcs ($ran checks)" || echo "FAIL bindcs"
exit $fail
