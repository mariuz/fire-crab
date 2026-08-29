#!/bin/bash
# CONCATENATING ACROSS CHARACTER SETS: a byte carrier is BYTES.
#
# `eval` joins two rendered strings and has no descriptors to convert
# against, so an operand whose character set differed from the result's
# was spliced in as it stood. That is broken in a way a String hides,
# because a String means different things per charset here: a byte
# carrier's octets ride one char per byte, a UTF8 column's are real
# characters.
#
# THE WORST OF IT WAS NOT A WRONG ANSWER. `<NONE> || <WIN1252>` carried
# the NONE octets as chars U+0073.. U+009F.., announced the result
# WIN1252, and then tried to TRANSLITERATE those chars into WIN1252 -
# where U+009F has no image, WIN1252 mapping 0x9F to U+0178. The
# transliteration failed MID-ROW, after bytes were already on the wire:
# the client got SQLSTATE 08006 and a DROPPED CONNECTION. The check
# below therefore asserts the session survives, not merely that the
# bytes agree.
#
# THE ENGINE'S LAW, probed: a byte carrier is bytes, and a conversion to
# or from one is a BYTE COPY, never a transliteration. So `<NONE> ||
# <WIN1252>` is simply the two operands' stored octets in order, read
# back in WIN1252. `transcode_text` already implemented exactly that;
# nothing called it from the concatenation path. Each operand whose
# charset is statically known is now converted to the result's set
# before joining, through the synthetic text CAST that invokes it.
#
# Two widths ride along, both measured:
#   * `cs_join` is the engine's own DataTypeUtil rule - OCTETS ABSORBS
#     from either side, NONE is the weakest, ASCII yields to all but
#     NONE - and this server already had it right.
#   * a BYTE-CARRIER RESULT counts BYTES, not characters: `<UTF8
#     VARCHAR(32)> || <OCTETS VARCHAR(32)>` is 160 bytes (32x4 + 32),
#     where summing characters announced 64. An announced width that
#     disagrees with the shipped bytes is the same wire desync as above.
#
# TWO RECORDED DIVERGENCES, asserted here so they cannot drift
# unnoticed - both are a LITERAL's charset, which is the ATTACHMENT's
# and therefore unknown when the node is built:
#   * `<NONE column> || <literal>` - the join is the attachment
#     sentinel, so no static conversion is possible and the carrier's
#     octets are still spliced as UTF-8. Fixing it needs the conversion
#     DEFERRED to emission, where the attachment is finally known; the
#     eval path has no attachment at all today. Note `<OCTETS> ||
#     <literal>` is CORRECT, because OCTETS absorbs and the join is
#     statically known.
#   * `CAST(<literal> AS ... CHARACTER SET WIN1252)` UNDER A NONE
#     ATTACHMENT - the engine byte-copies the literal's octets where
#     this transliterates. Under a UTF8 attachment it agrees.
# Neither is a refusal: both answer, with the wrong bytes. They are
# checked as KNOWN-DIFFERENT so that fixing them trips this gate.
#
#   qa/serve-real-concatcs.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4345}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-concatcs-a.fdb"
B="$D/fc-concatcs-b.fdb"

mkdir -p "$D"
setup() {
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE TX (ID INTEGER,
                 U VARCHAR(32) CHARACTER SET UTF8,
                 W VARCHAR(32) CHARACTER SET WIN1252,
                 N VARCHAR(32) CHARACTER SET NONE,
                 O VARCHAR(32) CHARACTER SET OCTETS);
COMMIT;
-- the NONE column holds the UTF-8 spelling of 'strasse' with an eszett;
-- the WIN1252 one holds 0x9F, whose Unicode image (U+0178) has no place
-- in Latin-1 - that byte is what turned a wrong answer into a dropped
-- connection
INSERT INTO TX VALUES (1, _UTF8 x'73747261C39F65', _WIN1252 x'737472619F65',
                          _NONE x'73747261C39F65', _OCTETS x'616263');
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0; while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-concatcs.log 2>&1 &
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

# describe AND the value's raw BYTES - these laws are invisible in
# rendered text, which is exactly how they survived
shape() { # <dsn> <select> [flags]
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" ${3:-} "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype|^R +|^X +|SQLSTATE' | head -3 | od -An -tx1 | tr -s ' \n' ' '
}
both() { # <label> <select> [flags]
    ran=$((ran + 1))
    e=$(shape "$EN" "$2" "${3:-}"); c=$(shape "$FC" "$2" "${3:-}")
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}
# a shape that is KNOWN to differ. Asserted so that FIXING it trips this
# gate rather than passing silently - a recorded divergence nobody
# re-checks is just a bug with better manners.
known_diff() { # <label> <select> [flags]
    ran=$((ran + 1))
    e=$(shape "$EN" "$2" "${3:-}"); c=$(shape "$FC" "$2" "${3:-}")
    if [ "$c" != "$e" ]; then echo "OK   still divergent (recorded): $1"
    else echo "DIFF $1 now AGREES - the divergence is fixed, update this gate"; fail=1; fi
}

echo "--- 1. the session must SURVIVE a cross-charset concatenation --------"
# the teeth for the 08006: run the query, then ask the SAME connection a
# second question. A dropped session cannot answer it.
ran=$((ran + 1))
alive=$(printf 'SET LIST ON;\nSELECT N || W AS R FROM TX WHERE ID=1;\nSELECT 42 AS STILL_HERE FROM RDB$DATABASE;\n' |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1)
case "$alive" in
    *08006*) echo "DIFF teeth: NONE || WIN1252 still drops the connection (08006)"; fail=1 ;;
    *STILL_HERE*42*) echo "OK   teeth: the connection survives and answers again" ;;
    *) echo "DIFF teeth: the session did not answer the follow-up: $(printf '%s' "$alive" | tr -s ' \n' ' ')"; fail=1 ;;
esac

echo "--- 2. every statically-known charset pair ---------------------------"
for CH in "" "-ch UTF8" "-ch WIN1252"; do
    l="${CH:-(default NONE)}"
    both "NONE || WIN1252 $l"   "SELECT N || W AS R FROM TX WHERE ID=1" "$CH"
    both "WIN1252 || NONE $l"   "SELECT W || N AS R FROM TX WHERE ID=1" "$CH"
    both "UTF8 || OCTETS $l"    "SELECT U || O AS R FROM TX WHERE ID=1" "$CH"
    both "OCTETS || UTF8 $l"    "SELECT O || U AS R FROM TX WHERE ID=1" "$CH"
    both "NONE || UTF8 $l"      "SELECT N || U AS R FROM TX WHERE ID=1" "$CH"
    both "UTF8 || NONE $l"      "SELECT U || N AS R FROM TX WHERE ID=1" "$CH"
    both "OCTETS || NONE $l"    "SELECT O || N AS R FROM TX WHERE ID=1" "$CH"
    both "WIN1252 || UTF8 $l"   "SELECT W || U AS R FROM TX WHERE ID=1" "$CH"
    both "UTF8 || UTF8, the control $l" "SELECT U || U AS R FROM TX WHERE ID=1" "$CH"
    both "OCTETS || literal, which absorbs $l" "SELECT O || '' AS R FROM TX WHERE ID=1" "$CH"
    both "UTF8 || literal $l"    "SELECT U || '' AS R FROM TX WHERE ID=1" "$CH"
    both "WIN1252 || literal $l" "SELECT W || '' AS R FROM TX WHERE ID=1" "$CH"
done

echo "--- 3. the CAST matrix across the same sets --------------------------"
both "CAST a NONE column to WIN1252"  "SELECT CAST(N AS VARCHAR(32) CHARACTER SET WIN1252) AS X FROM TX WHERE ID=1"
both "CAST a UTF8 column to OCTETS"   "SELECT CAST(U AS VARCHAR(32) CHARACTER SET OCTETS) AS X FROM TX WHERE ID=1"
both "CAST a WIN1252 column to NONE"  "SELECT CAST(W AS VARCHAR(32) CHARACTER SET NONE) AS X FROM TX WHERE ID=1"
both "CAST an OCTETS column to UTF8"  "SELECT CAST(O AS VARCHAR(32) CHARACTER SET UTF8) AS X FROM TX WHERE ID=1"
both "CAST a literal to WIN1252 under UTF8" \
    "SELECT CAST('x' AS VARCHAR(4) CHARACTER SET WIN1252) AS X FROM RDB\$DATABASE" "-ch UTF8"

echo "--- 4. the recorded divergences --------------------------------------"
known_diff "a NONE column concatenated with a literal" \
    "SELECT N || '' AS R FROM TX WHERE ID=1"
known_diff "... and with a non-empty one"  \
    "SELECT N || 'x' AS R FROM TX WHERE ID=1"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 42 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
