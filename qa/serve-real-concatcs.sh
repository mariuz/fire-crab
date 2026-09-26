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
-- section 8's rows: 'é' in every set (the NONE and OCTETS columns hold
-- its UTF-8 octets C3 A9), an ASCII row, a NULL row, and a NONE/OCTETS
-- E9 that no UTF8 spells
CREATE TABLE TN (ID INTEGER,
                 U VARCHAR(10) CHARACTER SET UTF8,
                 W VARCHAR(10) CHARACTER SET WIN1252,
                 N VARCHAR(10) CHARACTER SET NONE,
                 O VARCHAR(10) CHARACTER SET OCTETS);
COMMIT;
INSERT INTO TN VALUES (1, _UTF8 x'C3A9', _WIN1252 x'E9', _NONE x'C3A9', _OCTETS x'C3A9');
INSERT INTO TN VALUES (2, 'ab', 'ab', 'ab', x'4142');
INSERT INTO TN VALUES (3, NULL, NULL, NULL, NULL);
INSERT INTO TN VALUES (4, NULL, NULL, _NONE x'E9', _OCTETS x'E9');
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

echo "--- 4. what were the recorded divergences, now CLOSED -----------------"
# These two were `known_diff` until 2026-08-31: a CHARACTER SET NONE
# column concatenated with a literal came back with every high byte
# doubled (73747261C39F65 shipped as 73747261C383C29F65), because the
# carrier's chars were re-encoded as UTF-8 instead of travelling as the
# bytes they are. NONE yields its TAG to the other operand and never its
# BYTES. They are ordinary `both` checks now - the tripwire fired, which
# is what a recorded divergence is for.
both "a NONE column concatenated with a literal" \
    "SELECT N || '' AS R FROM TX WHERE ID=1"
both "... and with a non-empty one"  \
    "SELECT N || 'x' AS R FROM TX WHERE ID=1"

echo "--- 5. the CONCAT double-encode: VALUE diverges, DESCRIBE agrees ------"
# Measured 2026-09-17 across NONE / UTF8 / WIN1252 attachments with a
# NON-ASCII literal (an ASCII one transliterates identically everywhere
# and cannot show this at all - the first probe of it was vacuous):
#
#   -ch NONE     'e-acute' || U   engine CL 3 / OL 4   fc 4 / 6   (fc DOUBLES)
#                U || 'e-acute'   engine CL 3 / OL 4   fc 4 / 6
#   -ch WIN1252  'e-acute' || U   engine CL 4 / OL 4   fc 4 / 6   (literal FIRST only)
#   -ch UTF8     'e-acute' || W   engine CL 3 / OL 4   fc 3 / 3   (fc is SHORT)
#                'e-acute' || O   engine CL 4 / OL 4   fc 3 / 3
#
# THE ANNOUNCED DESCRIPTOR AGREES ON EVERY ONE OF THEM - sqltype, VARYING
# and charset are identical on both servers under all three attachments,
# and every column||column pair agrees too. So this is a VALUE defect in
# how operands are transcoded and joined, NOT the width algebra the
# withdrawn attempt steered by (that one broke on announced widths, 160
# vs 64, while values stayed byte-identical).
#
# The two NONE-attachment cells are FIXED (the literal is decoded into
# the column's set, its describe still measured in octets), and so, since
# the literal was given the attachment's REAL set in the join, are the
# other three. Recorded rather than fixed: three widths meet one join rule here (a
# literal carries a character count AND an octet count, resolve_text_cs
# picks between them by the ATTACHMENT), and the divergences pull in
# OPPOSITE directions. A rule that predicts all eighteen cells has not
# been found, and the last attempt was withdrawn after three designs each
# moved the failures between families.
lenpair() { # <dsn> <expr> <flags>
    printf 'SET HEADING OFF;\nSELECT CHAR_LENGTH(%s) AS CL, OCTET_LENGTH(%s) AS OL FROM TX WHERE ID=1;\n' "$2" "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" ${3:-} "$1" 2>&1 | tr -s ' \n' ' '
}
known_len_diff() { # <label> <expr> [flags]
    ran=$((ran + 1))
    e=$(lenpair "$EN" "$2" "${3:-}"); c=$(lenpair "$FC" "$2" "${3:-}")
    if [ -z "$e" ] || [ -z "$c" ]; then
        echo "DIFF $1 [VACUOUS: a side did not answer] engine=[$e] fc=[$c]"; fail=1
    elif [ "$c" != "$e" ]; then
        echo "OK   still divergent (recorded): $1 engine=[$e] fc=[$c]"
    else
        echo "DIFF $1 now AGREES - the double-encode is fixed, update this gate"; fail=1
    fi
}
# PROMOTED (qa/serve-real-psqlassign.sh 8e): under a BYTE-CARRIER
# attachment the literal's octets are READ AS the real operand's set
# before the join ([concat_operands]) - both servers answer the same
# CHAR_LENGTH and OCTET_LENGTH (the literal adds one character, two octets).
same_len() { # <label> <expr> [flags]
    ran=$((ran + 1))
    e=$(lenpair "$EN" "$2" "${3:-}"); c=$(lenpair "$FC" "$2" "${3:-}")
    if [ -z "$e" ] || [ "$c" != "$e" ]; then
        echo "FAIL $1 engine=[$e] fc=[$c]"; fail=1
    else
        echo "OK   $1 [$e]"
    fi
}
same_len "literal || UTF8 col, NONE attachment (it doubled)" "'é' || U" "-ch NONE"
same_len "UTF8 col || literal, NONE attachment (it doubled)" "U || 'é'" "-ch NONE"
# PROMOTED (qa/serve-real-psqlassign.sh 9a): under a REAL attachment the
# literal IS that set, so of two real sets the first operand's wins and
# OCTETS still absorbs - and the literal moves into the result set like
# any operand ([cs_join], [recode_concat]). The rule that predicts all
# of them was the join's, not the widths'.
same_len "literal || UTF8 col, WIN1252 attachment" "'é' || U" "-ch WIN1252"
same_len "literal || WIN1252 col, UTF8 attachment (it was 3 / 3)" "'é' || W" "-ch UTF8"
same_len "literal || OCTETS col, UTF8 attachment (it was 3 / 3)"  "'é' || O" "-ch UTF8"
# ...and the cells that must NOT move: every column||column pair agrees
# today, and the withdrawn attempt is exactly what broke them.
both "column || column stays right (UTF8||WIN1252)" "SELECT U || W AS R FROM TX WHERE ID=1"
both "column || column stays right (UTF8||OCTETS)"  "SELECT U || O AS R FROM TX WHERE ID=1"
both "column || column stays right (WIN1252||NONE)" "SELECT W || N AS R FROM TX WHERE ID=1"

echo "--- 6. a literal's value under CONTAINING, and a pattern built from literals ------"
# The join above types `'x' || U` as the ATTACHMENT's set, and a value of
# that set folds case in that set's law when the attachment names a real
# one (measured under UTF8: 'é' || U CONTAINING 'É' takes the row, 'xé'
# CONTAINING 'É' is true) - read as no set at all, the fold was NONE's,
# which leaves 'é' alone, and every one of these found nothing. A LIKE
# or STARTING WITH pattern that is a concatenation of literals is an
# expression pattern; read as a literal with a `||` left over, it refused.
both "a literal || UTF8 column CONTAINING folds in the attachment's set (it found nothing)" \
    "SELECT COUNT(*) AS R FROM TX WHERE 'é' || U CONTAINING 'É'" "-ch UTF8"
both "...the column's own eszett through the same fold" \
    "SELECT COUNT(*) AS R FROM TX WHERE 'x' || U CONTAINING 'ß'" "-ch UTF8"
both "...a literal || WIN1252 column" \
    "SELECT COUNT(*) AS R FROM TX WHERE 'xé' || W CONTAINING 'é'" "-ch UTF8"
both "a pure literal CONTAINING (it was false)" \
    "SELECT COUNT(*) AS R FROM TX WHERE 'xé' CONTAINING 'É'" "-ch UTF8"
both "...and under NONE the fold stays NONE's" \
    "SELECT COUNT(*) AS R FROM TX WHERE 'xé' CONTAINING 'É'" "-ch NONE"
both "a LIKE pattern that is 'str' || '%' (it refused)" \
    "SELECT COUNT(*) AS R FROM TX WHERE U LIKE 'str' || '%'" "-ch UTF8"
both "a STARTING WITH prefix that is 'st' || '' (it refused)" \
    "SELECT COUNT(*) AS R FROM TX WHERE U STARTING WITH 'st' || ''" "-ch UTF8"

echo "--- 7. a literal beside a binary literal, a q-string, an introducer, a literal under COLLATE, a bare CAST's NONE bytes ------"
# Found by the second review of the psqlassign section-10 fix. A UTF8
# literal beside a binary literal is as wide as ITS set's characters
# (VARCHAR(6) OCTETS for 'é' || x'4142', measured), where counting it one
# octet per character announced 3 and the four octets raised 22001 on the
# way out. A q-string is the literal it spells, an introducer types its
# octets (`_win1252 'é'` is the two WIN1252 characters C3 A9), a literal
# under COLLATE is of the attachment's set - and under NONE the engine's
# own -204, no such collation for NONE. A bare CAST is the attachment's
# set, NONE here, and a NONE operand MOVES BY ITS BYTES into the set a
# typed operand decides: C3 A9 read as UTF8 is 'é' (it was re-encoded to
# C3 83 C2 A9), and the WIN1252 column's 9F is no UTF8 - 22000, where
# the octets were answered. A folded scalar subquery of a real set keeps
# that set through the fold (it became a NONE literal, then 22000).
both "'é' || x'4142' is the four octets C3 A9 41 42 (it raised 22001: expected length 3, actual 4)" \
    "SELECT 'é' || x'4142' AS R FROM RDB\$DATABASE" "-ch UTF8"
both "x'4142' || 'é'" "SELECT x'4142' || 'é' AS R FROM RDB\$DATABASE" "-ch UTF8"
both "'éé' || x'41' (it raised expected 3, actual 5)" "SELECT 'éé' || x'41' AS R FROM RDB\$DATABASE" "-ch UTF8"
both "...under NONE the literal is two octets and the width is 4" "SELECT 'é' || x'4142' AS R FROM RDB\$DATABASE" "-ch NONE"
both "a q-string is the literal it spells (it refused)" "SELECT q'{it's}' AS R FROM RDB\$DATABASE" "-ch UTF8"
both "...in a predicate" "SELECT COUNT(*) AS R FROM TX WHERE U = q'[straße]'" "-ch UTF8"
both "_utf8 'é' || 'ab' is four octets (it refused)" "SELECT OCTET_LENGTH(_utf8 'é' || 'ab') AS R FROM RDB\$DATABASE" "-ch UTF8"
both "'ab' || _win1252 'é' under UTF8: C3 A9 is two WIN1252 characters, four UTF8 octets" \
    "SELECT OCTET_LENGTH('ab' || _win1252 'é') AS R FROM RDB\$DATABASE" "-ch UTF8"
both "...under NONE the literal yields to WIN1252" "SELECT OCTET_LENGTH('ab' || _win1252 'é') AS R FROM RDB\$DATABASE" "-ch NONE"
both "_utf8 x'C3A9' || 'a' types a binary literal" "SELECT _utf8 x'C3A9' || 'a' AS R FROM RDB\$DATABASE" "-ch UTF8"
both "U = 'STRAßE' COLLATE UNICODE_CI: a literal collates in the attachment's set (it refused)" \
    "SELECT COUNT(*) AS R FROM TX WHERE U = 'STRAßE' COLLATE UNICODE_CI" "-ch UTF8"
both "...under NONE the engine's -204: no such collation for NONE" \
    "SELECT COUNT(*) AS R FROM TX WHERE U = 'STRAßE' COLLATE UNICODE_CI" "-ch NONE"
both "a bare CAST's NONE octets move by BYTES into the UTF8 a typed operand decides (it re-encoded them)" \
    "SELECT CAST(CAST(U AS VARCHAR(10)) || CAST(x'78' AS CHAR(1) CHARACTER SET UTF8) AS VARCHAR(20) CHARACTER SET OCTETS) AS R FROM TX WHERE ID = 1" "-ch NONE"
both "...over the WIN1252 column: 9F is no UTF8, 22000 (it answered the octets)" \
    "SELECT CAST(CAST(W AS VARCHAR(10)) || CAST(x'78' AS CHAR(1) CHARACTER SET UTF8) AS VARCHAR(20) CHARACTER SET OCTETS) AS R FROM TX WHERE ID = 1" "-ch NONE"
both "a folded scalar subquery of a real set keeps it under NONE (it was 22000)" \
    "SELECT OCTET_LENGTH('a' || (SELECT CAST(x'C3A9' AS CHAR(1) CHARACTER SET UTF8) FROM RDB\$DATABASE)) AS R FROM RDB\$DATABASE" "-ch NONE"

echo "--- 8. a collation through a function, a NONE value through a conditional or a bare CAST under a real attachment, LOWER over a carrier ------"
# Found by the review of section 7's fix. A literal under COLLATE resolves
# since section 7, but the collation was DROPPED on the way through
# UPPER, LOWER, TRIM, SUBSTRING, LEFT, RIGHT, REPLACE, REVERSE, LPAD,
# COALESCE, IIF, CASE and NULLIF - the engine's result type for each is
# its argument's, collation included - so `UPPER('é' COLLATE UNICODE_CI)
# = U` counted 0 for 1; a CAST and a concatenation drop it (measured 0
# both), and a COALESCE takes its FIRST value's. A byte carrier beside an
# explicit collation MOVES INTO the collation's set before the compare
# (a NONE literal under -ch NONE, a NONE column under -ch UTF8), where
# the byte-space branch compared octets; OCTETS stays binary. Under a
# REAL attachment a NONE value that reaches a typed operand through
# COALESCE / IIF / CASE, or a bare CAST, was TRANSLITERATED (C3 A9 ->
# C3 83 C2 A9) where the engine copies its bytes ('é'); and LOWER over a
# carrier literal cased ASCII only on the engine where this folded the
# carrier chars into an octet no set spells. Every cell pins the value.
val() { # <dsn> <select> [flags]
    printf 'SET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" ${3:-} "$1" 2>&1 |
        grep -av '^ *$' | sed 's/  */ /g;s/ *$//' | paste -sd'|'
}
pinv() { # <label> <select> <flags> <engine-output>
    ran=$((ran + 1))
    local e c
    e=$(val "$EN" "$2" "${3:-}"); c=$(val "$FC" "$2" "${3:-}")
    if [ "$e" != "$4" ]; then echo "DIFF $1 - THE ENGINE ANSWERS [$e], not the pinned [$4]"; fail=1
    elif [ "$e" != "$c" ]; then echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1
    else echo "OK   $1 [$e]"; fi
}
MAL='Statement failed, SQLSTATE = 22000|Malformed string'
pinv "UPPER('é' COLLATE UNICODE_CI) = U (it counted 0)" "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UNICODE_CI) = U" "-ch UTF8" "R 1"
pinv "LOWER('É' COLLATE UNICODE_CI) = U" "SELECT COUNT(*) AS R FROM TN WHERE LOWER('É' COLLATE UNICODE_CI) = U" "-ch UTF8" "R 1"
pinv "TRIM('É' COLLATE UNICODE_CI) = U" "SELECT COUNT(*) AS R FROM TN WHERE TRIM('É' COLLATE UNICODE_CI) = U" "-ch UTF8" "R 1"
pinv "TRIM(LEADING 'z' FROM 'zÉ' COLLATE UNICODE_CI) = U" "SELECT COUNT(*) AS R FROM TN WHERE TRIM(LEADING 'z' FROM 'zÉ' COLLATE UNICODE_CI) = U" "-ch UTF8" "R 1"
pinv "SUBSTRING('É' COLLATE UNICODE_CI FROM 1) = U" "SELECT COUNT(*) AS R FROM TN WHERE SUBSTRING('É' COLLATE UNICODE_CI FROM 1) = U" "-ch UTF8" "R 1"
pinv "LEFT('Éz' COLLATE UNICODE_CI, 1) = U" "SELECT COUNT(*) AS R FROM TN WHERE LEFT('Éz' COLLATE UNICODE_CI, 1) = U" "-ch UTF8" "R 1"
pinv "REPLACE('Éz' COLLATE UNICODE_CI, 'z', '') = U" "SELECT COUNT(*) AS R FROM TN WHERE REPLACE('Éz' COLLATE UNICODE_CI, 'z', '') = U" "-ch UTF8" "R 1"
pinv "COALESCE('É' COLLATE UNICODE_CI, 'z') = U" "SELECT COUNT(*) AS R FROM TN WHERE COALESCE('É' COLLATE UNICODE_CI, 'z') = U" "-ch UTF8" "R 1"
pinv "COALESCE(NULL, 'É' COLLATE UNICODE_CI) = U: the first VALUE's collation" "SELECT COUNT(*) AS R FROM TN WHERE COALESCE(NULL, 'É' COLLATE UNICODE_CI) = U" "-ch UTF8" "R 1"
pinv "COALESCE('z', 'É' COLLATE UNICODE_CI) = U: the first value has none" "SELECT COUNT(*) AS R FROM TN WHERE COALESCE('z', 'É' COLLATE UNICODE_CI) = U" "-ch UTF8" "R 0"
pinv "IIF(TRUE, 'É' COLLATE UNICODE_CI, 'z') = U" "SELECT COUNT(*) AS R FROM TN WHERE IIF(TRUE, 'É' COLLATE UNICODE_CI, 'z') = U" "-ch UTF8" "R 1"
pinv "CASE WHEN TRUE THEN 'É' COLLATE UNICODE_CI ELSE 'z' END = U" "SELECT COUNT(*) AS R FROM TN WHERE CASE WHEN TRUE THEN 'É' COLLATE UNICODE_CI ELSE 'z' END = U" "-ch UTF8" "R 1"
pinv "NULLIF('É' COLLATE UNICODE_CI, 'z') = U" "SELECT COUNT(*) AS R FROM TN WHERE NULLIF('É' COLLATE UNICODE_CI, 'z') = U" "-ch UTF8" "R 1"
pinv "CAST('É' COLLATE UNICODE_CI AS VARCHAR(5)) = U: a CAST drops it" "SELECT COUNT(*) AS R FROM TN WHERE CAST('É' COLLATE UNICODE_CI AS VARCHAR(5)) = U" "-ch UTF8" "R 0"
pinv "'x' || UPPER('é' COLLATE UNICODE_CI) = 'x' || U: a concatenation drops it" "SELECT COUNT(*) AS R FROM TN WHERE 'x' || UPPER('é' COLLATE UNICODE_CI) = 'x' || U" "-ch UTF8" "R 0"
pinv "UPPER('é' COLLATE UNICODE_CI) <> U (it counted the 'é' row too)" "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UNICODE_CI) <> U" "-ch UTF8" "R 1"
pinv "UPPER('é' COLLATE UNICODE_CI_AI) = 'e' is true of every row" "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UNICODE_CI_AI) = 'e'" "-ch UTF8" "R 4"
pinv "UPPER('é' COLLATE UCS_BASIC) = U: the byte order" "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UCS_BASIC) = U" "-ch UTF8" "R 0"
pinv "UPPER(U COLLATE UNICODE_CI) = 'é': the column's side" "SELECT COUNT(*) AS R FROM TN WHERE UPPER(U COLLATE UNICODE_CI) = 'é'" "-ch UTF8" "R 1"
pinv "UPPER('é' COLLATE UNICODE_CI) = W: the WIN1252 column moves into the collation's set" "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UNICODE_CI) = W" "-ch UTF8" "R 1"
pinv "UPPER(U COLLATE UNICODE_CI) STARTING WITH 'é'" "SELECT COUNT(*) AS R FROM TN WHERE UPPER(U COLLATE UNICODE_CI) STARTING WITH 'é'" "-ch UTF8" "R 1"
pinv "UPPER(U COLLATE UNICODE_CI) LIKE 'é%'" "SELECT COUNT(*) AS R FROM TN WHERE UPPER(U COLLATE UNICODE_CI) LIKE 'é%'" "-ch UTF8" "R 1"
pinv "under NONE: U COLLATE UNICODE_CI = 'É' - the NONE literal C3 89 moves into UTF8 (it compared octets: 0)" "SELECT COUNT(*) AS R FROM TN WHERE U COLLATE UNICODE_CI = 'É'" "-ch NONE" "R 1"
pinv "under NONE: U COLLATE UNICODE_CI STARTING WITH 'É'" "SELECT COUNT(*) AS R FROM TN WHERE U COLLATE UNICODE_CI STARTING WITH 'É'" "-ch NONE" "R 1"
pinv "under NONE: U COLLATE UNICODE_CI IN ('É', 'x')" "SELECT COUNT(*) AS R FROM TN WHERE U COLLATE UNICODE_CI IN ('É', 'x')" "-ch NONE" "R 1"
pinv "N = CAST('É' AS VARCHAR(5) CHARACTER SET UTF8) COLLATE UNICODE_CI: the NONE column C3 A9 moves into UTF8" "SELECT COUNT(*) AS R FROM TN WHERE ID < 4 AND N = CAST('É' AS VARCHAR(5) CHARACTER SET UTF8) COLLATE UNICODE_CI" "-ch UTF8" "R 1"
pinv "...and the E9 row raises on the way in" "SELECT COUNT(*) AS R FROM TN WHERE N = CAST('É' AS VARCHAR(5) CHARACTER SET UTF8) COLLATE UNICODE_CI" "-ch UTF8" "$MAL"
pinv "CAST(N AS VARCHAR(5)) = 'É' COLLATE UNICODE_CI" "SELECT COUNT(*) AS R FROM TN WHERE ID < 4 AND CAST(N AS VARCHAR(5)) = 'É' COLLATE UNICODE_CI" "-ch UTF8" "R 1"
pinv "O = CAST('É' AS VARCHAR(5) CHARACTER SET UTF8) COLLATE UNICODE_CI: OCTETS stays binary" "SELECT COUNT(*) AS R FROM TN WHERE O = CAST('É' AS VARCHAR(5) CHARACTER SET UTF8) COLLATE UNICODE_CI" "-ch UTF8" "R 0"
known_diff "two explicit collations that disagree: UPPER('é' COLLATE UNICODE_CI) = U COLLATE UNICODE (engine 1, refused here)" \
    "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UNICODE_CI) = U COLLATE UNICODE" "-ch UTF8"
known_diff "a collated value LIKE a column: UPPER('é' COLLATE UNICODE_CI) LIKE U (engine 1, refused here)" \
    "SELECT COUNT(*) AS R FROM TN WHERE UPPER('é' COLLATE UNICODE_CI) LIKE U" "-ch UTF8"
pinv "COALESCE(N, 'q') || 'x' under UTF8: the NONE octets C3 A9 read as UTF8 (it was 'Ã©x')" "SELECT COALESCE(N, 'q') || 'x' AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éx"
pinv "COALESCE(N, 'q') alone" "SELECT COALESCE(N, 'q') AS R FROM TN WHERE ID = 1" "-ch UTF8" "R é"
pinv "...its octets" "SELECT CAST(COALESCE(N, 'q') || 'x' AS VARCHAR(20) CHARACTER SET OCTETS) AS R FROM TN WHERE ID = 1" "-ch UTF8" "R C3A978"
pinv "...its length (it was 4)" "SELECT OCTET_LENGTH(COALESCE(N, 'q')) AS R FROM TN WHERE ID = 1" "-ch UTF8" "R 2"
pinv "IIF(TRUE, N, 'q') || 'x'" "SELECT IIF(TRUE, N, 'q') || 'x' AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éx"
pinv "CASE WHEN TRUE THEN N ELSE 'q' END || 'x'" "SELECT CASE WHEN TRUE THEN N ELSE 'q' END || 'x' AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éx"
pinv "WHERE COALESCE(N, 'q') = 'é' (it counted 0)" "SELECT COUNT(*) AS R FROM TN WHERE ID < 4 AND COALESCE(N, 'q') = 'é'" "-ch UTF8" "R 1"
pinv "...over the E9 row too: 22000" "SELECT COUNT(*) AS R FROM TN WHERE COALESCE(N, 'q') = 'é'" "-ch UTF8" "$MAL"
pinv "UPPER(COALESCE(N, 'q'))" "SELECT UPPER(COALESCE(N, 'q')) AS R FROM TN WHERE ID = 1" "-ch UTF8" "R É"
pinv "COALESCE(N, U) || 'x'" "SELECT COALESCE(N, U) || 'x' AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éx"
pinv "COALESCE(N, 'q') || W" "SELECT COALESCE(N, 'q') || W AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éé"
pinv "NULLIF(N, 'q') || 'x' (a control: NULLIF is its first operand's set)" "SELECT NULLIF(N, 'q') || 'x' AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éx"
pinv "a bare CAST(N AS VARCHAR(5)) is the attachment's UTF8 with the octets moved (it re-encoded them: C383C2A9)" "SELECT CAST(CAST(N AS VARCHAR(5)) AS VARCHAR(5) CHARACTER SET OCTETS) AS R FROM TN WHERE ID = 1" "-ch UTF8" "R C3A9"
pinv "CAST(N AS VARCHAR(5)) || 'x'" "SELECT CAST(N AS VARCHAR(5)) || 'x' AS R FROM TN WHERE ID = 1" "-ch UTF8" "R éx"
pinv "OCTET_LENGTH(CAST(N AS VARCHAR(5)))" "SELECT OCTET_LENGTH(CAST(N AS VARCHAR(5))) AS R FROM TN WHERE ID = 1" "-ch UTF8" "R 2"
pinv "CAST(x'C3A9' AS VARCHAR(5)): a binary literal the same way" "SELECT CAST(x'C3A9' AS VARCHAR(5)) AS R FROM RDB\\$DATABASE" "-ch UTF8" "R é"
pinv "CAST(O AS VARCHAR(5)) over the OCTETS C3 A9" "SELECT CAST(O AS VARCHAR(5)) AS R FROM TN WHERE ID = 1" "-ch UTF8" "R é"
pinv "COALESCE(O, 'q') is OCTETS: the octets themselves" "SELECT COALESCE(O, 'q') AS R FROM TN WHERE ID = 1" "-ch UTF8" "R C3A9"
pinv "CAST(x'E9' AS VARCHAR(5)): no UTF8 spells E9, 22000" "SELECT CAST(x'E9' AS VARCHAR(5)) AS R FROM RDB\\$DATABASE" "-ch UTF8" "$MAL"
pinv "CAST(N AS VARCHAR(5)) over a NONE E9: 22000" "SELECT CAST(N AS VARCHAR(5)) AS R FROM TN WHERE ID = 4" "-ch UTF8" "$MAL"
pinv "COALESCE(N, 'q') over a NONE E9: 22000" "SELECT COALESCE(N, 'q') AS R FROM TN WHERE ID = 4" "-ch UTF8" "$MAL"
pinv "under NONE the pair stays NONE: COALESCE(N, 'q') || 'x' is the octets" "SELECT COALESCE(N, 'q') || 'x' AS R FROM TN WHERE ID = 1" "-ch NONE" "R éx"
pinv "LOWER('É') under NONE cases ASCII only: 'É' (it wrote an octet no set spells)" "SELECT LOWER('É') AS R FROM RDB\\$DATABASE" "-ch NONE" "R É"
pinv "...its length" "SELECT OCTET_LENGTH(LOWER('É')) AS R FROM RDB\\$DATABASE" "-ch NONE" "R 2"
pinv "LOWER('ÉA') under NONE" "SELECT LOWER('ÉA') AS R FROM RDB\\$DATABASE" "-ch NONE" "R Éa"
pinv "LOWER('É') || U under NONE (it raised 22000)" "SELECT LOWER('É') || U AS R FROM TN WHERE ID = 1" "-ch NONE" "R Éé"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 120 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
