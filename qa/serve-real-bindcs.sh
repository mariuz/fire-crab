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
                C CHAR(5) CHARACTER SET UTF8);
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

# RECORDED, NOT FIXED - measured here and left as it is, the honest way
# round (not an OK cell, and not hidden either):
#
#   A `?` TYPED BY A LITERAL is typed from the LITERAL, not defaulted.
#   `SELECT 1 FROM RDB$DATABASE WHERE ? = 'x'` describes on the engine as
#   452 TEXT len 1 (the literal's own character count) in the ATTACHMENT's
#   charset - len 4 cs 4 under UTF8, len 1 cs 53 under WIN1252 - where
#   fire-crab announces 448 VARYING len 32763 cs 0 on every attachment.
#   That is a SLOT TYPING defect, not an attachment one: it diverges under
#   a NONE attachment too, so it is a root of its own and belongs in its
#   own slice rather than being smuggled into this one.

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$WORK" "$REF"
[ "$ran" -ge 34 ] || { echo "FAIL only $ran checks ran (expected >= 34)"; fail=1; }
[ $fail = 0 ] && echo "PASS bindcs ($ran checks)" || echo "FAIL bindcs"
exit $fail
