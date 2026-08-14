#!/bin/bash
# A column's DESCRIBE carries its RDB$FIELD_SUB_TYPE. The exact-numeric
# family shares three dtypes with plain integers - a NUMERIC(9,2) and an
# INTEGER are both a scaled/unscaled LONG - and the SUB_TYPE is what
# tells them apart on the wire: 0 plain integer, 1 NUMERIC, 2 DECIMAL
# (probed against the engine). fire-crab had hardcoded 0 for every
# SHORT/LONG/INT64/INT128 column, announcing a NUMERIC(9,2) as a bare
# scaled LONG; it now passes the descriptor's own sub_type.
#
# Compared on the type name, scale, subtype and width - the leading
# sqltype number and the Nullable flag (fire-crab's own convention for
# every column) normalised away.
#
#   qa/serve-real-numsubtype.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4742}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  N92 NUMERIC(9,2), N40 NUMERIC(4,0), N184 NUMERIC(18,4), N385 NUMERIC(38,5),
  D92 DECIMAL(9,2), D40 DECIMAL(4,0),
  S SMALLINT, I INTEGER, B BIGINT
);
COMMIT;
INSERT INTO T VALUES (1.5, 1, 1.5, 1.5, 2.5, 2, 3, 4, 5);
COMMIT;
EOF
}
EDB="$D/fc-numsub-e.fdb"; FDB="$D/fc-numsub-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-numsub-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

ty() { printf 'SET SQLDA_DISPLAY ON;\nSELECT %s FROM T;\n' "$2" |
    "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE 'sqltype:' | head -1 |
    grep -oiE '(SHORT|LONG|INT64|INT128) .*subtype: [0-9]+ len: [0-9]+' | sed 's/Nullable //'; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { # <column>
    local e c
    e=$(ty "$E" "$1"); c=$(ty "$F" "$1")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
# NUMERIC columns: subtype 1, the width the precision names
both "N92"; both "N40"; both "N184"; both "N385"
# DECIMAL columns: subtype 2 (and DECIMAL(4,0) is a LONG, not a SHORT)
both "D92"; both "D40"
# plain integers keep subtype 0
both "S"; both "I"; both "B"

# NEGATION and the SELECTION nodes KEEP the widest operand's width (they
# do not widen to INT64 the way arithmetic does), and carry the subtype
# through - a scale-0 NUMERIC(4,0) is still subtype 1 though this server
# types it as a plain integer.
both "-N92"; both "-N40"; both "-I"; both "-S"
both "COALESCE(N92, N40)"      # LONG subtype 1 - the wider wins
both "COALESCE(N40, N184)"     # INT64 subtype 1
both "COALESCE(S, I)"          # LONG subtype 0 - plain integers
both "NULLIF(N92, N92)"        # LONG subtype 1
both "IIF(N40 > 0, N40, N40)"  # SHORT subtype 1 - scale-0 NUMERIC kept
# arithmetic still WIDENS to INT64, carrying the subtype
both "N40 + N40"               # INT64 subtype 1
both "I + 1"                   # INT64 subtype 0

# a BARE INTEGER LITERAL takes its width from its MAGNITUDE, as the engine
# does: <= i64::MAX is INT64/LONG, past that up to i128::MAX is INT128
# (subtype 0, len 16). Past i128::MAX is DECFLOAT, which stays refused.
# The wide literal was refused OUTRIGHT before - the select-list parser
# capped at i64.
both "5000000000"                              # INT64 (> i32, <= i64)
both "9223372036854775807"                     # INT64 (i64::MAX)
both "9223372036854775808"                     # INT128 (i64::MAX + 1)
both "99999999999999999999"                    # INT128 (20 digits)
both "170141183460469231731687303715884105727" # INT128 (i128::MAX)
# and the VALUE round-trips, not just the type
bothval() {
    local e c
    e=$(printf 'SELECT %s FROM RDB$DATABASE;\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | tr -s ' \n' ' ')
    c=$(printf 'SELECT %s FROM RDB$DATABASE;\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | tr -s ' \n' ' ')
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   value $1"; else echo "DIFF value $1"; echo "     engine: $e"; echo "     fcrab:  $c"; fail=1; fi
}
bothval "99999999999999999999"
bothval "170141183460469231731687303715884105727"

# WIDE-LITERAL ARITHMETIC: an integer expression over a wide literal keeps
# the engine's INT128 promotion, in the SELECT list AND inside a WHERE.
# The parser refused a Tok::Int128 as an expression atom before (only the
# bare projected/compared literal was carried); it now flows through
# RawExpr::Int128 into the shared arithmetic/eval path.
# type of the arithmetic result: INT128, subtype 0, len 16
both "99999999999999999999 + 1"                # operand is INT128
both "5000000000 * 5000000000"                 # both operands i64, product wide
both "170141183460469231731687303715884105727 + 0"  # i128::MAX identity
# and the value round-trips
bothval "99999999999999999999 + 1"             # 100000000000000000000
bothval "5000000000 * 5000000000"              # 25000000000000000000
bothval "99999999999999999999 * 2"             # 199999999999999999998
# a full-statement comparison, for the WHERE-expression side and for the
# i128-boundary OVERFLOW, which must raise (SQLSTATE 22003) not wrap
qval() {
    local e c
    e=$(printf '%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | tr -s ' \n' ' ' | sed 's/^ *//;s/ *$//')
    c=$(printf '%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | tr -s ' \n' ' ' | sed 's/^ *//;s/ *$//')
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   q $1"; else echo "DIFF q $1"; echo "     engine: $e"; echo "     fcrab:  $c"; fail=1; fi
}
# wide arithmetic inside WHERE, both sides of the comparison wide
qval "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 99999999999999999999 + 1 = 100000000000000000000;"
qval "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 5000000000 * 5000000000 = 25000000000000000000;"
qval "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 99999999999999999999 + 1 > 5;"
# i128::MAX + 1 and a wide*wide product both overflow INT128 - the engine
# raises rather than promoting to DECFLOAT, and so must the twin. The
# message wording differs (this server emits the shorter secondary line),
# so parity is checked on the SQLSTATE class alone.
qstate() {
    local e c
    e=$(printf '%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | grep -oiE 'SQLSTATE = [0-9]+' | head -1)
    c=$(printf '%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | grep -oiE 'SQLSTATE = [0-9]+' | head -1)
    ran=$((ran + 1))
    if [ -n "$e" ] && [ "$e" = "$c" ]; then echo "OK   raise $1 [$e]"; else echo "DIFF raise $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
qstate "SELECT 170141183460469231731687303715884105727 + 1 FROM RDB\$DATABASE;"
qstate "SELECT 100000000000000000000 * 100000000000000000000 FROM RDB\$DATABASE;"

# PAST i128::MAX a bare integer literal is a DECFLOAT(34) (sqltype 32762,
# len 16): the magnitude no longer fits an exact 128-bit integer, so the
# engine rounds it to 34 significant digits (HALF-UP) and carries it as an
# IEEE 754 decimal128. fire-crab now ENCODES that decimal128 (the DPD form)
# from the digits itself - the module was decode-only before - so the value
# decodes on the client to the same E-notation isql prints.
dfty() { printf 'SET SQLDA_DISPLAY ON;\nSELECT %s FROM T;\n' "$2" |
    "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE 'sqltype:' | head -1 |
    grep -oiE 'DECFLOAT\([0-9]+\) .*len: [0-9]+' | sed 's/Nullable //'; }
dfboth() { # <literal> - compares the DECFLOAT type name, scale-less, len
    local e c
    e=$(dfty "$E" "$1"); c=$(dfty "$F" "$1")
    ran=$((ran + 1))
    if [ -n "$e" ] && [ "$e" = "$c" ]; then echo "OK   df $1 [$e]"
    else echo "DIFF df $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
# type is DECFLOAT(34)/len 16, the boundary is MAGNITUDE > i128::MAX
dfboth "170141183460469231731687303715884105728"    # i128::MAX + 1
dfboth "340282366920938463463374607431768211455"    # u128::MAX (39 digits)
dfboth "9999999999999999999999999999999999999999999999999999" # 52 nines
dfboth "-170141183460469231731687303715884105729"   # negative, past i128::MIN
dfboth "-9999999999999999999999999999999999999999999999999999"
# the SIGN folds in before the type is chosen: exactly -2^127 is i128::MIN,
# an INT128 (len 16) - NOT DECFLOAT (the boundary the magnitude alone misses)
both "-170141183460469231731687303715884105728"
# and every value round-trips (rounded HALF-UP to 34 sig digits, sign carried)
bothval "170141183460469231731687303715884105728"
bothval "340282366920938463463374607431768211455"
bothval "9999999999999999999999999999999999999999999999999999"
bothval "222222222222222222222222222222222250000"    # exact-half -> UP (probed)
bothval "222222222222222222222222222222222249999"    # below-half  -> down
bothval "99999999999999999999999999999999999999999"   # all-nines carry -> 10^41
bothval "-170141183460469231731687303715884105728"   # -2^127 = i128::MIN, exact
bothval "-170141183460469231731687303715884105729"   # negative DECFLOAT
bothval "-9999999999999999999999999999999999999999999999999999"

echo "ran $ran checks"
exit $fail
