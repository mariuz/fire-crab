#!/bin/bash
# AN ICU COLLATION DECIDES THE ANSWER, AND THIS SERVER HAS NO TABLE FOR
# IT - so it refuses rather than answering by bytes.
#
# Firebird's `UNICODE`, `UNICODE_CI` and the language-specific
# collations are ICU-backed: their order is the Unicode Collation
# Algorithm's, where `'apple' < 'Ápple' < 'banana'` and (under CI)
# `'apple' = 'APPLE'`. The bytes say something else in both cases, and
# this server used to answer the bytes SILENTLY - the wrong rows out of
# a filter, the wrong ORDER out of a sort, the wrong number of GROUPS.
# Measured before the fix, over the fixture below: `ORDER BY CI` came
# back 5,2,1,6,3,4 where the engine answers 1,5,4,6,2,3; `WHERE CI =
# 'APPLE'` found ONE row where the engine finds two; `GROUP BY CI` made
# SIX groups where the engine makes four.
#
# What this gate pins:
#
#   * every place a collation decides an answer over an ICU-collated
#     column REFUSES - ORDER BY (a column or an expression over one),
#     the comparison family, LIKE / STARTING WITH / IN, GROUP BY,
#     DISTINCT, MIN/MAX, a JOIN key, and an explicit COLLATE clause
#   * every place it does NOT refuses nothing: a charset's DEFAULT
#     collation (byte order - `UCS_BASIC` for UTF8), `PXW_INTL` (the one
#     real collation converted, keys and all), and simply SELECTing an
#     ICU-collated column, which returns bytes and decides nothing
#
# The fixture is built by the ENGINE (this server does not create
# `COLLATE UNICODE_CI` columns) and both servers then read the same
# shapes over their own copy of it.
#
#   qa/serve-real-icucoll.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4929}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-icucoll-crab.fdb"
B="$D/fc-icucoll-engine.fdb"
LOG="/tmp/fc-serve-icucoll-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER,
  S  VARCHAR(20),
  CI VARCHAR(20) COLLATE UNICODE_CI,
  UC VARCHAR(20) COLLATE UNICODE,
  W  VARCHAR(20) CHARACTER SET WIN1252 COLLATE PXW_INTL);
COMMIT;
INSERT INTO T VALUES (1, 'apple',  'apple',  'apple',  'apple');
INSERT INTO T VALUES (2, 'Banana', 'Banana', 'Banana', 'Banana');
INSERT INTO T VALUES (3, 'cherry', 'cherry', 'cherry', 'cherry');
INSERT INTO T VALUES (4, 'Ápple',  'Ápple',  'Ápple',  'Ápple');
INSERT INTO T VALUES (5, 'APPLE',  'APPLE',  'APPLE',  'APPLE');
INSERT INTO T VALUES (6, 'banana', 'banana', 'banana', 'banana');
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() { # <label> <sql> - the two servers must agree
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
refuses() { # <label> <sql> - fc must refuse, and the ENGINE must answer
    ran=$((ran + 1))
    r=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1)
    case "$r:$e" in
        *"Dynamic SQL Error"*) case "$e" in
            *"Dynamic SQL Error"*) echo "DIFF the ENGINE refuses it too - the shape proves nothing: $1"; fail=1 ;;
            *) echo "OK   refuses (the engine answers): $1" ;;
        esac ;;
        *) echo "DIFF ANSWERED where an ICU collation decides: $1"; echo "     [$r]"; fail=1 ;;
    esac
}

# ---- what the collation does NOT decide, or decides in a way this
# ---- server can key: nothing changes ------------------------------------
both "the rows landed the same on both sides" \
  "SELECT ID, S, CI, UC, W FROM T ORDER BY ID;"
both "an ICU-collated column PROJECTED decides nothing" \
  "SELECT ID, CI, UC FROM T WHERE ID IN (1, 5) ORDER BY ID;"
both "a charset's DEFAULT collation is byte order (UCS_BASIC)" \
  "SELECT ID FROM T ORDER BY S; SELECT ID FROM T WHERE S = 'APPLE'; SELECT S FROM T GROUP BY S ORDER BY 1;"
both "PXW_INTL orders, compares and groups by its own keys" \
  "SELECT ID FROM T ORDER BY W; SELECT ID FROM T WHERE W = 'apple' ORDER BY ID; SELECT COUNT(*) FROM T GROUP BY W ORDER BY 1;"
both "MIN and MAX over the DEFAULT collation" \
  "SELECT MIN(S), MAX(S) FROM T;"
both "the LENGTHS and the CASTS of an ICU-collated value" \
  "SELECT CHAR_LENGTH(CI), OCTET_LENGTH(CI), CAST(CI AS VARCHAR(30)) FROM T WHERE ID = 4;"

# ---- what it DOES decide: refused, not guessed --------------------------
refuses "ORDER BY a UNICODE_CI column" "SELECT ID FROM T ORDER BY CI;"
refuses "ORDER BY a UNICODE column" "SELECT ID FROM T ORDER BY UC;"
refuses "ORDER BY an EXPRESSION over one" "SELECT ID FROM T ORDER BY CI || 'x';"
refuses "an explicit COLLATE in the ORDER BY" "SELECT ID FROM T ORDER BY S COLLATE UNICODE_CI;"
refuses "equality" "SELECT ID FROM T WHERE CI = 'APPLE';"
refuses "a range" "SELECT ID FROM T WHERE CI > 'b' ORDER BY ID;"
refuses "BETWEEN" "SELECT ID FROM T WHERE UC BETWEEN 'a' AND 'c' ORDER BY ID;"
refuses "an IN list" "SELECT ID FROM T WHERE CI IN ('APPLE', 'cherry') ORDER BY ID;"
refuses "LIKE" "SELECT ID FROM T WHERE CI LIKE 'a%' ORDER BY ID;"
refuses "STARTING WITH" "SELECT ID FROM T WHERE CI STARTING WITH 'A' ORDER BY ID;"
refuses "GROUP BY" "SELECT CI, COUNT(*) FROM T GROUP BY CI;"
refuses "DISTINCT" "SELECT DISTINCT CI FROM T;"
refuses "MIN / MAX" "SELECT MIN(CI), MAX(CI) FROM T;"
# and PXW_INTL with it: the FOLD compares plain values with no collation
# in reach, so it answered `MIN(W)` by bytes ('APPLE' where the engine
# answers 'apple'). Keying the fold is a slice of its own
refuses "MIN / MAX over PXW_INTL too - the fold has no collation" \
  "SELECT MIN(W), MAX(W) FROM T;"
refuses "COUNT(DISTINCT) over a collated column" \
  "SELECT COUNT(DISTINCT CI) FROM T;"
refuses "a JOIN keyed on it" "SELECT a.ID, b.ID FROM T a JOIN T b ON a.CI = b.CI;"
# the ENGINE side of a refusal check RUNS the statement, so a DML probe
# rolls back - the two files must stay identical for the read-back below
refuses "a DML WHERE over it" "UPDATE T SET S = 'x' WHERE CI = 'APPLE'; ROLLBACK;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, S, CI, UC, W FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
