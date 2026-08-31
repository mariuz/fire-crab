#!/bin/bash
# A STRING LITERAL IS BYTES IN THE ATTACHMENT'S CHARACTER SET, AND A
# BYTE CARRIER IS NEVER TRANSLITERATED.
#
# Two halves of one law, both measured against the live engine:
#
#  ENTRY. A literal in the statement text is CHARACTER SET <lc_ctype of
#  the attachment>, and its BYTES are the attachment's bytes. Under a
#  NONE attachment a lone 0xE9 is data, not an encoding error. fire-crab
#  ran the whole statement through from_utf8_lossy before the tokenizer
#  ever saw the literal, so that byte became U+FFFD and was then STORED.
#
#  PROPAGATION. CS_NONE and CS_OCTETS are byte carriers. NONE yields its
#  TAG to the other operand - `N || 'x'` describes as the other side's
#  charset - but it never yields its BYTES. fire-crab re-encoded the
#  carrier's chars as UTF-8, so `N || ''` over the bytes 73747261C39F65
#  shipped 73747261C383C29F65: each byte of the original re-read as a
#  Latin-1 codepoint.
#
# WHAT THIS GATE IS BUILT AROUND, all of it learned the hard way:
#
#  1. THREE ATTACHMENTS, ALWAYS. Some vectors AGREE under -ch UTF8 and
#     diverge under -ch NONE (the truncation check below is one). A gate
#     that runs isql's default alone scores a live corruption class as
#     green. Every vector runs under NONE, UTF8 and WIN1252.
#  2. BYTES, NEVER RENDERED TEXT. isql transcodes on display, so
#     `caf<E9>` and `caf<C3 A9>` can print identically. Every value goes
#     through CAST(... AS ... CHARACTER SET OCTETS) and OCTET_LENGTH.
#  3. RAW BYTES INTO THE .sql FILE. Three vectors contain bytes that are
#     not valid UTF-8. Any layer that normalises the file to UTF-8
#     destroys the vector and the test then passes against a statement
#     neither server ever received - so the files are built with printf
#     and VERIFIED with od before the run.
#  4. THE FIXTURE IS BUILT WITH BARE HEX LITERALS ONLY. fire-crab
#     refuses the _CHARSET introducer (`_OCTETS x'4142'`), so a fixture
#     written that way leaves those columns NULL on one side and every
#     later comparison compares NULL with NULL - green, and meaningless.
#  5. ERROR VECTORS, NOT "BOTH FAILED". One vector has the engine
#     succeeding where fire-crab raised; another has fire-crab
#     succeeding where the engine raises 22001; a third has both
#     refusing with DIFFERENT vectors. Folding those into "refused"
#     scores a wrong diagnostic as agreement, so the whole isql output
#     is compared, SQLSTATE and detail lines included.
#  6. ONE STATEMENT PER CONNECTION FOR DESCRIBES. With SQLDA_DISPLAY on,
#     a character-typed result as the THIRD statement of a connection
#     kills fire-crab's connection outright (08006, send_packet/send)
#     and every later statement returns 08006 - a dead tail a
#     diff-counter can read as agreement. That defect is NOT this
#     chunk's, but this gate must not be built on top of it.
#
#   qa/serve-real-litcs.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4774}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-litcs-a.fdb"; B="$D/fc-litcs-b.fdb"
fail=0; ran=0
mkdir -p "$D"
Q=/tmp/fc-litcs-$$.sql

mkdb() { # <dsn> - bare hex literals only (see note 4)
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET NONE;
CREATE TABLE T (ID INTEGER, N VARCHAR(32) CHARACTER SET NONE,
                W VARCHAR(16) CHARACTER SET WIN1252, U VARCHAR(16) CHARACTER SET UTF8);
COMMIT;
INSERT INTO T (ID, N) VALUES (1, x'73747261C39F65');
INSERT INTO T (ID, N, W, U) VALUES (5, x'C39F', x'9F', x'C39F');
COMMIT;
EOF
}
rm -f "$A" "$B"
mkdb "$A"; mkdb "127.0.0.1/$REAL:$B"
chmod 666 "$A" 2>/dev/null
# the fixture must actually hold the bytes, on BOTH sides, or nothing
# below means anything (note 4)
for dsn in "127.0.0.1/$REAL:$B" ; do
    got=$(printf 'SET HEADING OFF;\nSELECT OCTET_LENGTH(N) FROM T WHERE ID=1;\n' |
        timeout 30 "$ISQL" -q -user "$U" -pas "$P" "$dsn" 2>&1 | tr -dc '0-9')
    [ "$got" = "7" ] || { echo "FAIL fixture N is $got bytes, expected 7"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-litcs-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$Q"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

run() { # <dsn> <attachment charset>
    timeout 30 "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "$1" -i "$Q" 2>&1 |
        grep -av '^[[:space:]]*$' | tr -s ' ' | paste -sd'|'
}
both() { # <label> <sql> [charsets...]
    local lbl="$1" sql="$2"; shift 2
    local chs="${*:-NONE UTF8 WIN1252}"
    printf 'SET HEADING OFF;\n%s;\n' "$sql" > "$Q"
    for ch in $chs; do
        ran=$((ran + 1))
        local e f
        e=$(run "127.0.0.1/$REAL:$B" "$ch"); f=$(run "127.0.0.1/$PORT:$A" "$ch")
        if [ "$e" = "$f" ]; then
            echo "OK   [-ch $ch] $lbl: $(printf '%.72s' "$e")"
        else
            echo "DIFF [-ch $ch] $lbl"
            echo "     engine: $(printf '%.100s' "$e")"
            echo "     fcwire: $(printf '%.100s' "$f")"
            fail=1
        fi
    done
}

# the raw byte vectors (note 3)
E9=$(printf '\xe9'); NINEF=$(printf '\x9f'); SS=$(printf '\xc3\x9f'); EACC=$(printf '\xc3\xa9')

echo "--- 0. the vectors really do contain non-UTF-8 bytes -----------------"
ran=$((ran + 1))
printf "SELECT 'a%sb' FROM RDB\$DATABASE;\n" "$E9" > "$Q"
if od -An -tx1 "$Q" | tr -s ' ' | grep -q ' e9'; then
    echo "OK   the 0xE9 vector survives into the .sql file"
else
    echo "DIFF the 0xE9 byte did NOT reach the .sql file - every check below is void"
    fail=1
fi

echo "--- 1. propagation: NONE yields its tag, never its bytes -------------"
both "N || '' bytes"        "SELECT CAST(N || '' AS VARCHAR(64) CHARACTER SET OCTETS) FROM T WHERE ID=1"
both "N || 'x' bytes"       "SELECT CAST(N || 'x' AS VARCHAR(64) CHARACTER SET OCTETS) FROM T WHERE ID=1"
both "'' || N bytes"        "SELECT CAST('' || N AS VARCHAR(64) CHARACTER SET OCTETS) FROM T WHERE ID=1"
both "N || N (control)"     "SELECT CAST(N || N AS VARCHAR(64) CHARACTER SET OCTETS) FROM T WHERE ID=1"
both "N || W bytes"         "SELECT CAST(N || W AS VARCHAR(32) CHARACTER SET OCTETS) FROM T WHERE ID=5"
both "W || N bytes"         "SELECT CAST(W || N AS VARCHAR(32) CHARACTER SET OCTETS) FROM T WHERE ID=5"
both "U || N bytes"         "SELECT CAST(U || N AS VARCHAR(32) CHARACTER SET OCTETS) FROM T WHERE ID=5"
both "lengths of N || ''"   "SELECT OCTET_LENGTH(N||''), CHAR_LENGTH(N||'') FROM T WHERE ID=1"
both "UPPER/LOWER over NONE" "SELECT UPPER(N), LOWER(N) FROM T WHERE ID=1"
both "SUBSTRING over NONE"  "SELECT CAST(SUBSTRING(N FROM 1 FOR 4) AS VARCHAR(16) CHARACTER SET OCTETS) FROM T WHERE ID=1"
both "TRIM over NONE"       "SELECT CAST(TRIM(N) AS VARCHAR(16) CHARACTER SET OCTETS) FROM T WHERE ID=1"
both "equality on raw bytes" "SELECT ID FROM T WHERE N = x'73747261C39F65'"

echo "--- 2. entry: the literal's bytes are the attachment's ---------------"
both "lone E9 -> OCTETS"     "SELECT CAST('a${E9}b' AS VARCHAR(8) CHARACTER SET OCTETS) FROM RDB\$DATABASE"
both "lone E9 -> WIN1252"    "SELECT CAST(CAST('a${E9}b' AS VARCHAR(4) CHARACTER SET WIN1252) AS VARCHAR(64) CHARACTER SET OCTETS) FROM RDB\$DATABASE"
both "lone 9F -> OCTETS"     "SELECT CAST('a${NINEF}b' AS VARCHAR(8) CHARACTER SET OCTETS) FROM RDB\$DATABASE"
both "literal lengths"       "SELECT OCTET_LENGTH('a${EACC}b'), CHAR_LENGTH('a${EACC}b') FROM RDB\$DATABASE"
both "ASCII literal (control)" "SELECT CAST('abc' AS VARCHAR(8) CHARACTER SET OCTETS) FROM RDB\$DATABASE"
both "valid UTF-8 literal"   "SELECT CAST('a${EACC}b' AS VARCHAR(8) CHARACTER SET OCTETS) FROM RDB\$DATABASE"

echo "--- 3. the error vectors, which run in BOTH directions ---------------"
# the engine SUCCEEDS here under NONE and REFUSES under UTF8 - and the
# refusal is a DSQL -104, not the value-level "Malformed string"
both "raw E9 into WIN1252"   "SELECT CAST(CAST('a${E9}b' AS VARCHAR(4) CHARACTER SET WIN1252) AS VARCHAR(64) CHARACTER SET OCTETS) FROM RDB\$DATABASE"
# fire-crab used to SUCCEED here where the engine raises 22001 - the
# inversion. It agrees under -ch UTF8, which is exactly why note 1 exists
both "6 bytes into VARCHAR(4)" "SELECT CAST(CAST('a${EACC}${EACC}b' AS VARCHAR(4) CHARACTER SET WIN1252) AS VARCHAR(64) CHARACTER SET OCTETS) FROM RDB\$DATABASE"

echo "--- 4. the write path, asserted by READBACK not by return code -------"
both "store E9 into NONE"    "DELETE FROM T WHERE ID=91; INSERT INTO T (ID,N) VALUES (91,'a${E9}b'); COMMIT; SELECT CAST(N AS VARCHAR(8) CHARACTER SET OCTETS), OCTET_LENGTH(N) FROM T WHERE ID=91"
both "store E9 into WIN1252" "DELETE FROM T WHERE ID=92; INSERT INTO T (ID,W) VALUES (92,'a${E9}b'); COMMIT; SELECT CAST(W AS VARCHAR(8) CHARACTER SET OCTETS), OCTET_LENGTH(W) FROM T WHERE ID=92"
both "store UTF-8 into UTF8"  "DELETE FROM T WHERE ID=93; INSERT INTO T (ID,U) VALUES (93,'a${EACC}b'); COMMIT; SELECT CAST(U AS VARCHAR(8) CHARACTER SET OCTETS), OCTET_LENGTH(U) FROM T WHERE ID=93"
both "store ASCII (control)"  "DELETE FROM T WHERE ID=94; INSERT INTO T (ID,N) VALUES (94,'plain'); COMMIT; SELECT N, OCTET_LENGTH(N) FROM T WHERE ID=94"

echo "--- 5. self-consistency, true WITHOUT reference to the engine --------"
# For CHARACTER SET NONE characters ARE bytes, so CHAR_LENGTH must equal
# OCTET_LENGTH. fire-crab shipped 9 bytes under a 7-character
# announcement - an announced width that is not the width written, this
# project's named desynchronisation hazard. This catches a half-fix that
# corrects the payload and leaves the metadata behind (or the reverse).
for ch in NONE WIN1252; do
    ran=$((ran + 1))
    printf 'SET HEADING OFF;\nSELECT OCTET_LENGTH(N||%s), CHAR_LENGTH(N||%s) FROM T WHERE ID=1;\n' "''" "''" > "$Q"
    got=$(run "127.0.0.1/$PORT:$A" "$ch" | tr -dc '0-9 ' | tr -s ' ')
    o=$(echo "$got" | awk '{print $1}'); c=$(echo "$got" | awk '{print $2}')
    if [ -n "$o" ] && [ "$o" = "$c" ]; then
        echo "OK   [-ch $ch] NONE self-consistency: CHAR_LENGTH = OCTET_LENGTH = $o"
    else
        echo "DIFF [-ch $ch] NONE self-consistency: OCTET_LENGTH=$o CHAR_LENGTH=$c - fire-crab is"
        echo "     announcing one width and writing another, engine or no engine"
        fail=1
    fi
done

echo "--- 6. the describe, one statement per connection (note 6) -----------"
desc() { # <label> <sql>
    ran=$((ran + 1))
    printf 'SET SQLDA_DISPLAY ON;\nSET HEADING OFF;\n%s;\n' "$2" > "$Q"
    local e f
    e=$(timeout 30 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$Q" 2>&1 | grep -aE '^ *0[0-9]: sqltype' | sed 's/  */ /g' | paste -sd'|')
    f=$(timeout 30 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$Q" 2>&1 | grep -aE '^ *0[0-9]: sqltype' | sed 's/  */ /g' | paste -sd'|')
    if [ "$e" = "$f" ] && [ -n "$e" ]; then echo "OK   $1: $e"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $f"; fail=1; fi
}
desc "N || 'x' announces a charset" "SELECT N || 'x' FROM T WHERE ID=1"
desc "N alone"                      "SELECT N FROM T WHERE ID=1"
desc "a bare literal"               "SELECT 'abc' FROM RDB\$DATABASE"

echo "----------------------------------------------------------------------"
echo "ran $ran checks"
[ "$ran" -ge 60 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
