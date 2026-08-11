#!/bin/bash
# CAST to a TEXT type - VARCHAR(n) and CHAR(n) - the value feature. A
# source of any family renders to its text form and is FIT to the target
# width; this server evaluated the render but mishandled the width, so a
# value that did not already fit raised a bare "Dynamic SQL Error".
#
# The width rule, measured against the live engine:
#
#   * the first `len` characters survive; overflow beyond `len` that is
#     ALL TRAILING BLANKS drops silently (CAST('ab   ' AS VARCHAR(3)) is
#     'ab '), so a value shorter-once-trimmed still fits;
#   * a NON-blank overflow raises - a TEXT source is 22001 *string right
#     truncation* ("expected length N, actual M"), while a rendered
#     NUMERIC source is 22018 *conversion error from string "..."* (the
#     two error classes the engine assigns, probed);
#   * CHAR pads the survivor to exactly `len` with blanks; VARCHAR keeps
#     it as it is.
#
# Sources exercised: string, INTEGER, NUMERIC/DECIMAL, DATE, BOOLEAN.
#
# Reduced to the value (bracketed to make trailing blanks visible) or the
# error class, so column widths and the engine's longer message text
# never read as a divergence. Values only - the CHAR describe is a known
# convention divergence (this server announces every text result VARYING
# 448 where the engine names fixed CHAR 452 SQL_TEXT), covered where it
# is decided, not here.
#
#   qa/serve-real-casttext.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4757}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, S VARCHAR(20), N INTEGER, D DECIMAL(9,2), DT DATE);
COMMIT;
INSERT INTO T VALUES (1, 'ab   ', 42, 3.14, DATE'2020-06-15');
INSERT INTO T VALUES (2, 'abcdefgh', 12345, 1234567.89, DATE'1999-12-31');
COMMIT;
EOF
}
EDB="$D/fc-casttext-e.fdb"; FDB="$D/fc-casttext-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-casttext-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

# reduce to the bracketed value or the error class
red() { printf 'SET HEADING OFF;\n%s;\n' "$2" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | grep -v '^$' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
    grep -oiE 'conversion error from string "[^"]*"|string right truncation|expected length [0-9]+ actual [0-9]+|\[[^]]*\]' | tr '\n' ' '; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { # <expr> <id>
    local e c
    e=$(red "$E" "SELECT '[' || $1 || ']' FROM T WHERE ID=$2")
    c=$(red "$F" "SELECT '[' || $1 || ']' FROM T WHERE ID=$2")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 (id $2) [$e]"
    else echo "DIFF $1 (id $2)"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
# --- a string source: fits, blank-fit, non-blank overflow (22001) -------------
both "CAST(S AS VARCHAR(20))" 1        # fits
both "CAST(S AS VARCHAR(3))"  1        # 'ab   ' -> 'ab ' (trailing blanks drop)
both "CAST(S AS VARCHAR(2))"  1        # 'ab   ' -> 'ab'
both "CAST(S AS VARCHAR(3))"  2        # 'abcdefgh' -> 22001
both "CAST(S AS CHAR(6))"     1        # pad to 6
both "CAST(S AS CHAR(3))"     2        # 'abcdefgh' -> 22001 (CHAR too)
# --- an INTEGER source: renders, overflow is 22018 ----------------------------
both "CAST(N AS VARCHAR(10))" 1        # 42
both "CAST(N AS VARCHAR(10))" 2        # 12345
both "CAST(N AS VARCHAR(3))"  2        # 12345 -> 22018
both "CAST(N AS CHAR(6))"     1        # 42 padded
# --- a NUMERIC source ---------------------------------------------------------
both "CAST(D AS VARCHAR(10))" 1        # 3.14
both "CAST(D AS VARCHAR(12))" 2        # 1234567.89
both "CAST(D AS VARCHAR(4))"  2        # 1234567.89 -> 22018
# --- a DATE source: a temporal renders like a string, so its overflow is
#     22001 (NOT the 22018 a numeric earns) - probed ------------------------
both "CAST(DT AS VARCHAR(20))" 1       # 2020-06-15
both "CAST(DT AS CHAR(12))"    2       # 1999-12-31 padded
both "CAST(DT AS VARCHAR(5))"  1       # does not fit -> 22001 string trunc
# BOUNDARY (not covered): CAST(<boolean> AS VARCHAR) - the engine renders
# TRUE/FALSE, but a boolean comparison is not a scalar cast operand in
# this server's planner, so it refuses. The eval already renders a
# Value::Bool; only the plan path is missing. Its own slice.

# --- the VARCHAR describe matches (type name + length) ------------------------
dt() { printf 'SET SQLDA_DISPLAY ON;\nSELECT %s FROM T;\n' "$2" |
    "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE 'sqltype:' | head -1 |
    grep -oiE 'VARYING .*len: [0-9]+' | sed 's/Nullable //'; }
dboth() { # <expr>
    local e c
    e=$(dt "$E" "$1"); c=$(dt "$F" "$1")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   describe $1 [$e]"
    else echo "DIFF describe $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
dboth "CAST(S AS VARCHAR(5))"
dboth "CAST(N AS VARCHAR(8))"

echo "ran $ran checks"
exit $fail
