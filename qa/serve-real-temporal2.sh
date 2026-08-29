#!/bin/bash
# THE TEMPORAL CLUSTER: zoned arithmetic, the shape of a difference, and
# the natural width of a temporal rendered as text.
#
# 1. DATEADD OVER A ZONED OPERAND ANSWERED A PLAUSIBLE-LOOKING LIE.
#    `Expr::eval`'s DateAdd arm decomposed Date/Time/Timestamp and sent
#    everything else to `_ => Ok(Value::Null)` with the comment
#    "type-checked away" - but `type_of` accepts EVERY TKind, the zoned
#    ones included. So the NULL travelled under a NOT NULL describe: the
#    encoder omitted the bytes and the client decoded their absence as
#    `1858-11-16 00:01:00.0000 -23:59`, the Modified Julian Day epoch
#    with zone id 0. That reads as a timestamp, not as a missing value,
#    which is why it survived: EVERY DATEADD over a TIMESTAMP WITH TIME
#    ZONE answered it, for every part and every amount.
#
#    The law, measured: the result is the operand's own type, the
#    arithmetic runs on the STORED UTC halves under ordinary zoneless
#    calendar rules, and the zone id rides through UNCHANGED. The
#    decisive probe is on a RULED zone, where instant-arithmetic and
#    local-field arithmetic differ: DATEADD(DAY, 1, '2024-03-30 12:00
#    Europe/Berlin') is 03-31 13:00 - twenty-four hours of instant
#    across the DST step - which local-field arithmetic cannot produce.
#    (fire-crab refuses ruled-zone literals, so that case is the
#    engine's measurement; the fixed-offset probes below pass under
#    either hypothesis and the implementation follows the measured one.)
#
# 2. DATEDIFF OVER A ZONED PAIR ANSWERED A CONSTANT 0, from the same
#    omission. DATEDIFF measures the UTC INSTANT, never the wall clock -
#    the same wall clock under different offsets is NONZERO, and that is
#    the check with teeth here because it distinguishes the two models.
#
# 3. THE SHAPE OF A TEMPORAL DIFFERENCE. `result_scale` already knew it;
#    the width, the rank and the sub_type did not, so DATE - DATE
#    announced INT64 len 8 for a 4-byte LONG and both scaled differences
#    announced sub_type 0 instead of NUMERIC's 1. The width error
#    CASCADED: rank_of saw no numeric rank on either operand, fell to its
#    (None, None) default of Long, Sub widened to I64 and `* 2` promoted
#    to INT128 where the engine stays INT64. All four now read ONE
#    classifier so they cannot drift apart again.
#
# 4. A TEMPORAL RENDERED AS TEXT HAS A NATURAL WIDTH - DATE 10, TIME 13,
#    TIMESTAMP 25 - where every implicit conversion fell into the 32765
#    catch-all. The temporal contributes a WIDTH but NO CHARSET: the
#    text operand alone decides that. Mid-fix, a trailing catch-all
#    fixed the LITERALS and left every COLUMN at 32765, because a
#    temporal column has its own earlier `Expr::Col` arm - hence the
#    test is now the FIRST thing text_form does.
#    The string functions split, and not the way one would guess: UPPER,
#    LOWER, TRIM and SUBSTRING over a temporal announce charset ASCII
#    (re-announced as the attachment's under a real one), while LEFT,
#    RIGHT, REVERSE, LPAD and REPLACE announce NONE and STAY NONE. Both
#    families are checked, because the rule is not uniform and the
#    second was already correct.
#
#   qa/serve-real-temporal2.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4349}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-temporal2-a.fdb"
B="$D/fc-temporal2-b.fdb"

mkdir -p "$D"
setup() {
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL, D DATE, TM TIME, TS TIMESTAMP);
COMMIT;
INSERT INTO T VALUES (1, DATE '2026-01-31', TIME '12:00:00', TIMESTAMP '2026-01-31 12:00:00');
INSERT INTO T VALUES (2, DATE '2026-03-01', TIME '01:30:00', TIMESTAMP '2026-01-30 06:00:00');
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0; while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-temporal2.log 2>&1 &
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

shape() { # <dsn> <select> [flags]
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        timeout 25 "$ISQL" -q -user "$U" -pas "$P" ${3:-} "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype|^[A-Z0-9_]+ +|SQLSTATE' | head -4 | od -An -c | tr -s ' \n' ' '
}
both() { # <label> <select> [flags]
    ran=$((ran + 1))
    e=$(shape "$EN" "$2" "${3:-}"); c=$(shape "$FC" "$2" "${3:-}")
    if [ "$c" = "$e" ] && [ -n "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fcwire: $c"; fail=1; fi
}

TZ="TIMESTAMP '2026-01-31 12:00:00 +02:00'"

echo "--- 1. DATEADD over a zoned operand ----------------------------------"
for part in YEAR MONTH WEEK DAY HOUR MINUTE SECOND MILLISECOND; do
    both "DATEADD $part over a zoned timestamp"    "SELECT DATEADD($part, 1, $TZ) A FROM RDB\$DATABASE"
    both "DATEADD $part, negative"                 "SELECT DATEADD($part, -3, $TZ) A FROM RDB\$DATABASE"
done
both "the month-end clamp survives the zone" "SELECT DATEADD(MONTH, 1, $TZ) A FROM RDB\$DATABASE"
both "a zoned TIME wraps modulo 24h and keeps its offset" \
    "SELECT DATEADD(HOUR, 20, TIME '10:20:30 +02:00') A FROM RDB\$DATABASE"
both "the zoneless control, which never moved" \
    "SELECT DATEADD(HOUR, 1, TIMESTAMP '2026-01-31 12:00:00') A FROM RDB\$DATABASE"

# THE TEETH: the old answer was a FIXED value, identical for every part
# and amount. Two different DATEADDs must not agree with each other.
ran=$((ran + 1))
h=$(printf 'SET HEADING OFF;\nSELECT DATEADD(HOUR,1,%s) FROM RDB$DATABASE;\n' "$TZ" |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | tr -s ' \n' ' ')
y=$(printf 'SET HEADING OFF;\nSELECT DATEADD(YEAR,1,%s) FROM RDB$DATABASE;\n' "$TZ" |
    timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$FC" 2>&1 | tr -s ' \n' ' ')
case "$h$y" in
    *1858-11-16*) echo "DIFF teeth: still answering the zeroed epoch value"; fail=1 ;;
    *) if [ "$h" = "$y" ]; then echo "DIFF teeth: +1 HOUR and +1 YEAR gave the SAME value [$h]"; fail=1
       else echo "OK   teeth: the parts answer differently, and none is the epoch"; fi ;;
esac

echo "--- 2. DATEDIFF over a zoned pair ------------------------------------"
both "DATEDIFF HOUR"  "SELECT DATEDIFF(HOUR FROM $TZ TO TIMESTAMP '2026-02-01 12:00:00 +02:00') A FROM RDB\$DATABASE"
both "DATEDIFF DAY"   "SELECT DATEDIFF(DAY FROM $TZ TO TIMESTAMP '2026-03-01 12:00:00 +02:00') A FROM RDB\$DATABASE"
both "DATEDIFF MONTH" "SELECT DATEDIFF(MONTH FROM $TZ TO TIMESTAMP '2026-11-01 12:00:00 +02:00') A FROM RDB\$DATABASE"
# the check with teeth: the SAME WALL CLOCK under DIFFERENT offsets is a
# real difference, which is what proves the UTC-instant law rather than
# a wall-clock one
both "the same wall clock, different offsets, is NOT zero" \
    "SELECT DATEDIFF(HOUR FROM TIMESTAMP '2026-01-31 12:00:00 +02:00' TO TIMESTAMP '2026-01-31 12:00:00 +05:00') A FROM RDB\$DATABASE"
both "the same INSTANT under different offsets IS zero" \
    "SELECT DATEDIFF(HOUR FROM TIMESTAMP '2026-01-31 12:00:00 +02:00' TO TIMESTAMP '2026-01-31 15:00:00 +05:00') A FROM RDB\$DATABASE"
both "the zoneless control" \
    "SELECT DATEDIFF(HOUR FROM TIMESTAMP '2026-01-31 12:00:00' TO TIMESTAMP '2026-02-01 12:00:00') A FROM RDB\$DATABASE"

echo "--- 3. the shape of a temporal difference ----------------------------"
both "DATE - DATE"            "SELECT DATE '2026-03-01' - DATE '2026-01-31' B FROM RDB\$DATABASE"
both "TIME - TIME"            "SELECT TIME '12:00:00' - TIME '01:30:00' A FROM RDB\$DATABASE"
both "TIMESTAMP - TIMESTAMP"  "SELECT TIMESTAMP '2026-01-31 12:00:00' - TIMESTAMP '2026-01-30 06:00:00' A FROM RDB\$DATABASE"
both "over COLUMNS, not literals" "SELECT D - DATE '2026-01-01' A FROM T WHERE ID=1"
both "through the aggregates"  "SELECT MAX(TS)-MIN(TS) B FROM T"
# the cascade: the seed width decides every downstream width
both "(DATE - DATE) * 2"      "SELECT (DATE '2026-03-01' - DATE '2026-01-31')*2 C FROM RDB\$DATABASE"
both "(TIME - TIME) * 2"      "SELECT (TIME '12:00:00' - TIME '01:30:00')*2 A FROM RDB\$DATABASE"
both "(TIMESTAMP - TIMESTAMP) * 2" \
    "SELECT (TIMESTAMP '2026-01-31 12:00:00' - TIMESTAMP '2026-01-30 06:00:00')*2 A FROM RDB\$DATABASE"
both "SUM of a difference widens one step" "SELECT SUM(D - DATE '2026-01-01') A FROM T"
both "COALESCE keeps the seed width"       "SELECT COALESCE(D - DATE '2026-01-01', 0) A FROM T WHERE ID=1"
both "unary minus keeps it"                "SELECT -(D - DATE '2026-01-01') A FROM T WHERE ID=1"
# a temporal minus a NUMBER is a different operation and must not move
both "DATE - <number>, which must not move" "SELECT D - 1 A FROM T WHERE ID=1"
both "TIMESTAMP - <number>"                 "SELECT TS - 1.5 A FROM T WHERE ID=1"

echo "--- 4. a temporal rendered as text -----------------------------------"
for CH in "" "-ch UTF8"; do
    l="${CH:-(default NONE)}"
    both "a DATE LITERAL concatenated $l"  "SELECT DATE '2026-01-31' || '' A FROM RDB\$DATABASE" "$CH"
    both "a DATE COLUMN concatenated $l"   "SELECT D || 'x' A FROM T WHERE ID=1" "$CH"
    both "a TIME column $l"                "SELECT TM || '' B FROM T WHERE ID=1" "$CH"
    both "a TIMESTAMP column $l"           "SELECT TS || '' C FROM T WHERE ID=1" "$CH"
    both "two temporals concatenated $l"   "SELECT DATE '2026-01-31' || TIME '12:00:00' A FROM RDB\$DATABASE" "$CH"
    # the ASCII family
    both "UPPER over a temporal $l"        "SELECT UPPER(D) A FROM T WHERE ID=1" "$CH"
    both "LOWER over a temporal $l"        "SELECT LOWER(D) A FROM T WHERE ID=1" "$CH"
    both "TRIM over a temporal $l"         "SELECT TRIM(TS) A FROM T WHERE ID=1" "$CH"
    both "SUBSTRING over a temporal $l"    "SELECT SUBSTRING(TS FROM 1 FOR 4) A FROM T WHERE ID=1" "$CH"
    # ... and the family that stays NONE
    both "LEFT over a temporal stays NONE $l"    "SELECT LEFT(TS,4) A FROM T WHERE ID=1" "$CH"
    both "RIGHT over a temporal stays NONE $l"   "SELECT RIGHT(D,2) A FROM T WHERE ID=1" "$CH"
    both "REVERSE over a temporal stays NONE $l" "SELECT REVERSE(D) A FROM T WHERE ID=1" "$CH"
    both "LPAD over a temporal stays NONE $l"    "SELECT LPAD(D,12) A FROM T WHERE ID=1" "$CH"
    both "REPLACE over a temporal stays NONE $l" "SELECT REPLACE(D,'-','/') A FROM T WHERE ID=1" "$CH"
    both "an explicit CAST, the control $l"      "SELECT CAST(D AS VARCHAR(40)) E FROM T WHERE ID=1" "$CH"
done

echo "----------------------------------------------------------------------"
[ "$ran" -ge 60 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
