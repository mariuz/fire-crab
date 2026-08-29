#!/bin/bash
# CAST to the INTEGER family - the string grammar and the width check,
# measured against the live engine:
#
#   * a STRING source takes the engine's number grammar, not a plain
#     integer parse: a fraction ROUNDS half away from zero ('2.5' -> 3,
#     '-2.5' -> -3, '2.49' -> 2), an exponent is read ('1e3' -> 1000),
#     leading/trailing 0x20 blanks drop, and a hex literal converts
#     ('0x10' -> 16);
#   * the value must fit the TARGET width or it is SQLSTATE 22003
#     "numeric value is out of range" - for a STRING source
#     (CAST('32768' AS SMALLINT)), an INTEGER source
#     (CAST(2147483648 AS INTEGER)) and an APPROXIMATE one
#     (CAST(1.23e30 AS BIGINT)) alike;
#   * a magnitude past i128 is out of range too, NOT a conversion error;
#   * a NON-NUMERIC spelling stays SQLSTATE 22018 "conversion error from
#     string" (CAST('abc' ...), CAST('1 2' ...) - CAST is strict, an
#     internal blank does not skip as the lenient comparison grammar's
#     does).
#
# All differential: the same statement to the engine and to fire-crab,
# reduced to the number or the error class so a stray spacing does not
# read as a divergence.
#
#   qa/serve-real-castint.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4740}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-castint-$PORT.log"
fail=0; ran=0
mkdir -p "$D"

mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
}
EDB="$D/fc-castint-e.fdb"
FDB="$D/fc-castint-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

# reduce an answer to the NUMBER or the ERROR CLASS - the two things that
# must agree - so trailing spaces or column widths never read as a diff
q() { printf 'SET HEADING OFF;\n%s\n' "$2" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' |
    grep -oiE 'out of range|conversion error from string "[^"]*"|-?[0-9]+' | tr '\n' ' '
}
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { # <expr>
    local e c
    e=$(q "$E" "SELECT $1 FROM RDB\$DATABASE;")
    c=$(q "$F" "SELECT $1 FROM RDB\$DATABASE;")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}

# --- the string grammar: fractions round, exponents read, hex converts ---------
both "CAST('2.5' AS INTEGER)"
both "CAST('-2.5' AS INTEGER)"
both "CAST('2.49' AS INTEGER)"
both "CAST('0.5' AS INTEGER)"
both "CAST('1.5' AS INTEGER)"
both "CAST('1e3' AS INTEGER)"
both "CAST('1.5e2' AS INTEGER)"
both "CAST('  3.7  ' AS INTEGER)"
both "CAST('12.5' AS SMALLINT)"
both "CAST('3.9' AS BIGINT)"
both "CAST('0x10' AS INTEGER)"

# --- the width check: 22003 for string, integer and approximate sources -------
both "CAST('32767' AS SMALLINT)"
both "CAST('32768' AS SMALLINT)"
both "CAST('-32768' AS SMALLINT)"
both "CAST('99999' AS SMALLINT)"
both "CAST('99999' AS INTEGER)"
both "CAST('99999999999' AS INTEGER)"
both "CAST('1e30' AS INTEGER)"
both "CAST(99999 AS SMALLINT)"
both "CAST(2147483648 AS INTEGER)"
both "CAST(1.23e30 AS BIGINT)"
both "CAST(2.5 AS INTEGER)"

# --- non-numeric stays 22018 conversion error, strict on internal blanks ------
both "CAST('abc' AS INTEGER)"
both "CAST('1 2' AS INTEGER)"

# --- and the SCALED family obeys the same width check -------------------------
# Only the i64 edge used to be checked, so a value that overflowed a
# NARROWER target wrapped silently: CAST(123456789012.34 AS NUMERIC(9,2))
# answered 19428925.30, a plausible wrong number where the engine raises.
#
# It is the STORAGE WIDTH, not the declared precision. The engine ACCEPTS
# CAST(15000000.00 AS NUMERIC(9,2)) although 9 digits at scale 2 top out
# at 9999999.99 - the 4-byte slot is what it checks - and the boundaries
# land exactly on the integer limits, negatives included.
both "CAST(327.67 AS NUMERIC(4,2))"
both "CAST(327.68 AS NUMERIC(4,2))"
both "CAST(-327.68 AS NUMERIC(4,2))"
both "CAST(-327.69 AS NUMERIC(4,2))"
both "CAST(21474836.47 AS NUMERIC(9,2))"
both "CAST(21474836.48 AS NUMERIC(9,2))"
both "CAST(-21474836.48 AS NUMERIC(9,2))"
both "CAST(-21474836.49 AS NUMERIC(9,2))"
both "CAST(922337203685477.5807 AS NUMERIC(18,4))"
both "CAST(123456789012.34 AS NUMERIC(9,2))"
both "CAST(123456789012.34 AS NUMERIC(4,2))"
# the PRECISION is deliberately NOT the limit - these must be accepted
both "CAST(15000000.00 AS NUMERIC(9,2))"
both "CAST(10000000.00 AS NUMERIC(9,2))"
both "CAST(100.00 AS NUMERIC(4,2))"
# and the ordinary cases must not have moved
both "CAST(1.50 AS NUMERIC(9,2))"
both "CAST(9999999.996 AS NUMERIC(9,2))"
both "CAST(123456789012.34 AS NUMERIC(18,2))"
both "CAST(1.5 AS DECIMAL(4,2))"

# --- the OUTPUT describe: a CAST to an integer type announces THAT type,
#     not the INT64 an arithmetic expression takes (probed: SMALLINT is
#     500 SHORT len 2, INTEGER 496 LONG len 4, BIGINT 580 INT64 len 8).
#     Compared on the type NAME and width - fire-crab announces every
#     expression NULLABLE by its own convention (the odd sqltype), so the
#     leading number and the Nullable flag are normalised away.
dtype() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" |
    "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
    grep -iE 'sqltype:' | head -1 |
    grep -oiE '(SHORT|LONG|INT64|INT128) .*len: [0-9]+' | sed 's/Nullable //'
}
dboth() { # <expr>
    local e c
    e=$(dtype "$E" "SELECT $1 FROM RDB\$DATABASE")
    c=$(dtype "$F" "SELECT $1 FROM RDB\$DATABASE")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   describe $1 [$e]"
    else echo "DIFF describe $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
dboth "CAST(1 AS SMALLINT)"
dboth "CAST(1 AS INTEGER)"
dboth "CAST(1 AS BIGINT)"
dboth "-CAST(1 AS SMALLINT)"
# arithmetic AROUND a cast widens to INT64 - the cast type does not escape
dboth "CAST(1 AS SMALLINT) + 1"
# a CAST to NUMERIC/DECIMAL names the target's storage type, scale, and
# SUB_TYPE (1 NUMERIC, 2 DECIMAL) - the same width rule as the integer
# cast plus the subtype the two spellings differ by. (Arithmetic AROUND
# a numeric cast widens to INT64 and the engine keeps the subtype there;
# fire-crab loses it - a broad subtype-propagation gap left for its own
# slice, so only the bare and negated casts are pinned here.)
dboth "CAST(1 AS NUMERIC(4,0))"
dboth "CAST(1 AS NUMERIC(9,2))"
dboth "CAST(1 AS NUMERIC(18,4))"
dboth "CAST(1 AS NUMERIC(38,5))"
dboth "CAST(1 AS DECIMAL(4,0))"
dboth "CAST(1 AS DECIMAL(9,2))"
dboth "-CAST(1 AS NUMERIC(9,2))"
# the subtype PROPAGATES through arithmetic - it is the MAX of the
# operand subtypes (DECIMAL's 2 dominates NUMERIC's 1, both dominate a
# literal's 0), and the width widens to INT64 around the arithmetic
dboth "CAST(1 AS NUMERIC(9,2)) + 1"
dboth "CAST(1 AS DECIMAL(9,2)) + 1"
dboth "CAST(1 AS NUMERIC(9,2)) + CAST(1 AS DECIMAL(9,2))"
# COALESCE KEEPS the operand width (a LONG here) rather than widening,
# and takes the wider subtype - DECIMAL's 2
dboth "COALESCE(CAST(1 AS DECIMAL(9,2)), CAST(1 AS NUMERIC(9,2)))"

echo "ran $ran checks"
exit $fail
