#!/bin/bash
# TEMPORAL ARITHMETIC - DATEADD, DATEDIFF, and the native operators.
#
#   DATEADD(1 MONTH TO d) / DATEADD(MONTH, 1, d)    both syntaxes
#   DATEDIFF(DAY, a, b)   / DATEDIFF(DAY FROM a TO b)
#   D + 7, 7 + D, D - 7, TS + 1, DATE - DATE, TS - TS, TIME - TIME
#
# The laws are the content, each probed against the live engine BEFORE
# implementation:
#
#   * MONTH/YEAR adds CLAMP to the target month's end: 2024-01-31 +1
#     MONTH is 2024-02-29; the leap day +1 YEAR is 2025-02-28
#   * a TIME wraps around midnight (23:30 +2 HOUR is 01:30); a DATE
#     absorbs clock units by truncation (+2 HOUR leaves the day, +25
#     HOUR moves one)
#   * DATEDIFF is b - a SIGNED; YEAR/MONTH difference calendar
#     COMPONENTS (MONTH from 01-31 to 03-01 is 2 - not a duration);
#     WEEK is the day difference over 7 truncating; the clock units
#     count BOUNDARY CROSSINGS (SECOND across .1234 -> .0000 is 1,
#     MINUTE across :59:59 -> :00:01 is 1)
#   * DATEDIFF(MILLISECOND) keeps the 0.1-ms digit: NUMERIC(18,1),
#     567.8 - not an integer
#   * the native differences carry fixed types: DATE - DATE is integer
#     days; TIME - TIME is seconds at scale -4 (16512.3456); any pair
#     with a TIMESTAMP is days at scale -9 (0.074075502, truncating)
#   * a NUMERIC addend rounds half away from zero first: D + 0.5 moves
#     a day (the engine's CVT round, not floor)
#
# DATEDIFF is admitted to WHERE (it cannot raise); DATEADD is not (an
# out-of-range result raises, and a WHERE term cannot carry the
# engine's mid-cursor error) - the refusal checks pin both choices.
#
#   qa/serve-real-datemath.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4490}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-datemath.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  D DATE,
  TM TIME,
  TS TIMESTAMP
);
COMMIT;
INSERT INTO T VALUES (1, DATE '2024-02-29', TIME '14:35:12.3456', TIMESTAMP '2001-09-09 01:46:40.1234');
INSERT INTO T VALUES (2, DATE '1999-01-01', TIME '00:00:00',      TIMESTAMP '2024-12-31 23:59:59.9999');
INSERT INTO T VALUES (3, NULL, NULL, NULL);
INSERT INTO T VALUES (4, DATE '2024-01-31', TIME '23:30:00',      TIMESTAMP '1970-01-01 00:00:00');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-datemath.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}
sameh() { # headers ON
    fc=$(printf '%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n=' ' ')
    en=$(printf '%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n=' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- DATEADD: calendar units and the clamp -----------------------------
same "both syntaxes, month clamp"   "SELECT DATEADD(1 MONTH TO D), DATEADD(MONTH, 1, D) FROM T ORDER BY ID"
same "leap day + 1 YEAR clamps"     "SELECT DATEADD(1 YEAR TO DATE '2024-02-29') FROM T WHERE ID = 1"
same "negative amounts"             "SELECT DATEADD(-1 DAY TO DATE '2024-03-01'), DATEADD(-1 MONTH TO DATE '2024-03-31') FROM T WHERE ID = 1"
same "WEEK adds seven days"         "SELECT DATEADD(1 WEEK TO D) FROM T ORDER BY ID"
same "over a column, every row"     "SELECT DATEADD(1 MONTH TO D) FROM T ORDER BY ID"

# --- DATEADD: clock units ----------------------------------------------
same "TIME wraps around midnight"   "SELECT DATEADD(2 HOUR TO TM) FROM T ORDER BY ID"
same "minutes over a timestamp"     "SELECT DATEADD(90 MINUTE TO TS) FROM T ORDER BY ID"
same "clock units on a DATE"        "SELECT DATEADD(2 HOUR TO D), DATEADD(25 HOUR TO D) FROM T ORDER BY ID"
same "milliseconds on a TIME"       "SELECT DATEADD(500 MILLISECOND TO TM) FROM T ORDER BY ID"
same "seconds across midnight"      "SELECT DATEADD(3600 SECOND TO TIME '23:30:00') FROM T WHERE ID = 1"

# --- DATEDIFF: components, boundaries, sign ----------------------------
same "DAY and YEAR"                 "SELECT DATEDIFF(DAY, DATE '1999-01-01', D), DATEDIFF(YEAR, DATE '1999-06-01', D) FROM T ORDER BY ID"
same "MONTH is a component diff"    "SELECT DATEDIFF(MONTH FROM DATE '2024-01-31' TO DATE '2024-03-01') FROM T WHERE ID = 1"
same "signed both ways"             "SELECT DATEDIFF(DAY, D, DATE '1999-01-01'), DATEDIFF(MONTH, DATE '2024-03-01', DATE '2024-01-31') FROM T WHERE ID = 1"
same "WEEK truncates day diff / 7"  "SELECT DATEDIFF(WEEK, DATE '2024-01-01', D) FROM T ORDER BY ID"
same "HOUR over times"              "SELECT DATEDIFF(HOUR, TIME '01:00:00', TM) FROM T ORDER BY ID"
same "SECOND counts boundaries"     "SELECT DATEDIFF(SECOND, TS, TIMESTAMP '2001-09-09 01:46:41.0000') FROM T WHERE ID = 1"
same "MINUTE across the boundary"   "SELECT DATEDIFF(MINUTE, TIME '10:59:59', TIME '11:00:01') FROM T WHERE ID = 1"
same "MILLISECOND keeps its digit"  "SELECT DATEDIFF(MILLISECOND, TIME '10:00:00.0000', TIME '10:00:00.5678') FROM T WHERE ID = 1"
same "mixed DATE and TIMESTAMP"     "SELECT DATEDIFF(DAY, TS, DATE '2024-01-01') FROM T ORDER BY ID"

# --- the native operators ----------------------------------------------
same "date plus and minus days"     "SELECT D + 7, D - 7, 7 + D FROM T ORDER BY ID"
same "timestamp plus a day"         "SELECT TS + 1 FROM T ORDER BY ID"
same "numeric addend rounds"        "SELECT D + 0.5 FROM T WHERE ID = 1"
same "DATE - DATE is integer days"  "SELECT D - DATE '1999-01-01' FROM T ORDER BY ID"
same "TS - TS is days at scale -9"  "SELECT TS - TIMESTAMP '2001-09-09 00:00:00' FROM T WHERE ID = 1"
same "TIME - TIME is seconds at -4" "SELECT TM - TIME '10:00:00' FROM T ORDER BY ID"

# --- composition -------------------------------------------------------
same "DATEDIFF in WHERE"            "SELECT ID FROM T WHERE DATEDIFF(YEAR, D, DATE '2024-06-01') < 5"
same "DATEDIFF under CASE"          "SELECT CASE WHEN DATEDIFF(DAY, D, CURRENT_DATE) > 365 THEN 'old' ELSE 'new' END FROM T ORDER BY ID"
same "aggregates over the results"  "SELECT MIN(D + 30), MAX(DATEDIFF(DAY, D, DATE '2024-06-01')) FROM T"
same "EXTRACT of a DATEADD"         "SELECT EXTRACT(MONTH FROM DATEADD(1 MONTH TO D)) FROM T ORDER BY ID"
same "GROUP BY a DATEDIFF"          "SELECT DATEDIFF(YEAR, D, DATE '2024-06-01'), COUNT(*) FROM T GROUP BY DATEDIFF(YEAR, D, DATE '2024-06-01') ORDER BY 1"
# a temporal-valued CALL on the left of a comparison against a temporal
# literal: this was a REFUSAL here until the predicate resolver learned
# temporal columns, and it is a comparison now - so it is checked as one
same "a DATEADD compared to a DATE literal" "SELECT ID FROM T WHERE DATEADD(1 DAY TO D) > DATE '2024-01-01' ORDER BY ID"
same "a DATEADD compared to a DATE column"  "SELECT ID FROM T WHERE DATEADD(1 DAY TO D) > D ORDER BY ID"

# --- headers -----------------------------------------------------------
sameh "header DATEADD"              "SELECT DATEADD(1 DAY TO D) FROM T WHERE ID = 1"
sameh "header DATEDIFF"             "SELECT DATEDIFF(DAY, D, D) FROM T WHERE ID = 1"
sameh "headers ADD/SUBTRACT"        "SELECT D + 1, D - DATE '1999-01-01' FROM T WHERE ID = 1"
sameh "TIME + n is SECONDS, wrapped" "SELECT TM + 1, TM - 1, TM + 1.5 FROM T WHERE ID = 1"

# --- refusals ----------------------------------------------------------
# (SELECT TM + 1 left this list when TIME +/- n arrived - the amount is
# SECONDS with the fraction kept, wrapping at midnight, and the
# differential below pins it; the old refusal was a recorded divergence)
for bad in "SELECT DATEADD(1 MONTH TO TM) FROM T" \
           "SELECT DATEDIFF(DAY, TM, D) FROM T" \
           "SELECT DATEADD(1 WEEKDAY TO D) FROM T"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the clamp and the truncating nanodays, pinned to values ----
v=$(printf 'SET HEADING OFF;\nSELECT DATEADD(1 MONTH TO DATE %s) FROM T WHERE ID = 1;\n' "'2024-01-31'" |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "2024-02-29" ]; then
    echo "OK   teeth: +1 MONTH on Jan 31 clamps to the leap day"
else
    echo "DIFF the month clamp gave [$v], want 2024-02-29"; fail=1
fi
v=$(printf 'SET HEADING OFF;\nSELECT TS - TIMESTAMP %s FROM T WHERE ID = 1;\n' "'2001-09-09 00:00:00'" |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "0.074075502" ]; then
    echo "OK   teeth: the timestamp difference truncates to 9 exact digits"
else
    echo "DIFF TS - TS gave [$v], want 0.074075502"; fail=1
fi

exit $fail
