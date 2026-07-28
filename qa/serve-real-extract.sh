#!/bin/bash
# THE TEMPORAL EXPRESSION SURFACE - EXTRACT, temporal literals, the
# clock keywords, and DATE/TIME/TIMESTAMP columns as expression operands.
#
#   EXTRACT(<part> FROM <temporal>)     part of a date/time value
#   DATE 'yyyy-mm-dd', TIME 'hh:mm:ss.ffff', TIMESTAMP '<date> <time>'
#   CURRENT_DATE / LOCALTIME / LOCALTIMESTAMP
#
# The conventions are the content, each probed against the live engine
# BEFORE implementation:
#
#   * EXTRACT(WEEKDAY) is 0 = Sunday (2024-02-29 -> 4, a Thursday)
#   * EXTRACT(YEARDAY) is 0-BASED (Jan 1st -> 0; 2024-02-29 -> 59)
#   * EXTRACT(WEEK) is the ISO 8601 week number - 1999-01-01 answers 53,
#     the last week OF 1998
#   * EXTRACT(SECOND) keeps its fraction: NUMERIC(9,4), 12.3456
#   * EXTRACT(MILLISECOND) is the fraction in ms: NUMERIC(9,1), 345.6
#   * a part that does not exist in the operand's kind fails at PREPARE
#     (the engine's -105); fire-crab refuses there too (generic 42000 -
#     the specific -105 text is a noted difference, not a silent one)
#   * a DATE compared against a TIMESTAMP converts as midnight
#   * LOCALTIME truncates the fractional second (hh:mm:ss.0000)
#
# CLOCK CAVEAT: CURRENT_DATE / LOCALTIME / LOCALTIMESTAMP are captured
# at PLAN time (the engine fixes them per statement execution) - for
# isql, which executes right after preparing, the values agree; the
# differential uses only day-safe checks so a midnight rollover between
# the two runs is the only race. CURRENT_TIME / CURRENT_TIMESTAMP are
# TIME ZONE types and stay refusals.
#
#   qa/serve-real-extract.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4486}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-extract.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  D DATE,
  TM TIME,
  TS TIMESTAMP,
  S VARCHAR(20)
);
COMMIT;
INSERT INTO T VALUES (1, DATE '2024-02-29', TIME '14:35:12.3456', TIMESTAMP '2001-09-09 01:46:40.1234', 'x');
INSERT INTO T VALUES (2, DATE '1999-01-01', TIME '00:00:00',      TIMESTAMP '2024-12-31 23:59:59.9999', 'y');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL);
INSERT INTO T VALUES (4, DATE '1858-11-17', TIME '23:59:59',      TIMESTAMP '1970-01-01 00:00:00', 'epoch');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-extract.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

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

# --- EXTRACT over DATE: the calendar parts -----------------------------
same "YEAR/MONTH/DAY"       "SELECT EXTRACT(YEAR FROM D), EXTRACT(MONTH FROM D), EXTRACT(DAY FROM D) FROM T ORDER BY ID"
same "WEEKDAY (0 = Sunday)" "SELECT EXTRACT(WEEKDAY FROM D) FROM T ORDER BY ID"
same "YEARDAY (0-based)"    "SELECT EXTRACT(YEARDAY FROM D) FROM T ORDER BY ID"
same "WEEK (ISO 8601)"      "SELECT EXTRACT(WEEK FROM D) FROM T ORDER BY ID"
same "the MJD epoch row"    "SELECT EXTRACT(YEAR FROM D), EXTRACT(WEEKDAY FROM D) FROM T WHERE ID = 4"

# --- EXTRACT over TIME: the clock parts --------------------------------
same "HOUR/MINUTE"          "SELECT EXTRACT(HOUR FROM TM), EXTRACT(MINUTE FROM TM) FROM T ORDER BY ID"
same "SECOND keeps its fraction (NUMERIC 9,4)" "SELECT EXTRACT(SECOND FROM TM) FROM T ORDER BY ID"
same "MILLISECOND (NUMERIC 9,1)" "SELECT EXTRACT(MILLISECOND FROM TM) FROM T ORDER BY ID"

# --- EXTRACT over TIMESTAMP: both families -----------------------------
same "date parts of a timestamp" "SELECT EXTRACT(YEAR FROM TS), EXTRACT(MONTH FROM TS), EXTRACT(WEEKDAY FROM TS), EXTRACT(WEEK FROM TS) FROM T ORDER BY ID"
same "time parts of a timestamp" "SELECT EXTRACT(HOUR FROM TS), EXTRACT(MINUTE FROM TS), EXTRACT(SECOND FROM TS) FROM T ORDER BY ID"
same "the second boundary row"   "SELECT EXTRACT(SECOND FROM TS), EXTRACT(MILLISECOND FROM TS) FROM T WHERE ID = 2"

# --- temporal columns and literals through the surface -----------------
same "plain temporal projection"  "SELECT D, TM, TS FROM T ORDER BY ID"
same "date renders under concat"  "SELECT D || '!' FROM T ORDER BY ID"
same "COALESCE with a DATE literal" "SELECT COALESCE(D, DATE '2000-01-01') FROM T ORDER BY ID"
same "COALESCE with a TIME literal" "SELECT COALESCE(TM, TIME '09:00:00') FROM T ORDER BY ID"
same "CASE on a date equality"    "SELECT CASE WHEN D = DATE '2024-02-29' THEN 'leap' ELSE 'no' END FROM T ORDER BY ID"
same "IIF on a timestamp compare" "SELECT IIF(TS > TIMESTAMP '2001-01-01 00:00:00', 'after', 'before') FROM T ORDER BY ID"
same "DATE vs TIMESTAMP converts" "SELECT CASE WHEN TS > DATE '2001-09-09' THEN 'after-midnight' ELSE 'no' END FROM T ORDER BY ID"
same "EXTRACT in arithmetic"      "SELECT EXTRACT(DAY FROM D) * 100 + EXTRACT(MONTH FROM D) FROM T ORDER BY ID"
same "EXTRACT under IIF"          "SELECT IIF(EXTRACT(MONTH FROM D) = 2, 'feb', 'other') FROM T ORDER BY ID"
same "nested: EXTRACT of a COALESCE" "SELECT EXTRACT(YEAR FROM COALESCE(D, DATE '2000-01-01')) FROM T ORDER BY ID"

# --- EXTRACT in WHERE (the predicate surface) --------------------------
same "WHERE EXTRACT ="            "SELECT ID FROM T WHERE EXTRACT(YEAR FROM D) = 2024"
same "WHERE EXTRACT BETWEEN"      "SELECT ID FROM T WHERE EXTRACT(MONTH FROM D) BETWEEN 1 AND 2 ORDER BY ID"
same "WHERE EXTRACT AND plain"    "SELECT ID FROM T WHERE EXTRACT(WEEKDAY FROM D) = 4 AND ID > 0"
same "WHERE EXTRACT IS NULL"      "SELECT ID FROM T WHERE EXTRACT(YEAR FROM D) IS NULL"
same "COUNT with EXTRACT filter"  "SELECT COUNT(*) FROM T WHERE EXTRACT(YEAR FROM D) > 1900"

# --- the clock keywords (day-safe checks only) -------------------------
same "CURRENT_DATE"               "SELECT CURRENT_DATE FROM T WHERE ID = 1"
same "EXTRACT of CURRENT_DATE"    "SELECT EXTRACT(YEAR FROM CURRENT_DATE) FROM T WHERE ID = 1"
same "CURRENT_DATE in a compare"  "SELECT IIF(D < CURRENT_DATE, 'past', 'future') FROM T ORDER BY ID"
# LOCALTIME/LOCALTIMESTAMP describe correctly even over zero rows - the
# empty result proves the announce without racing the clock
same "LOCALTIME describes"        "SELECT LOCALTIME FROM T WHERE ID = 0"
same "LOCALTIMESTAMP describes"   "SELECT LOCALTIMESTAMP FROM T WHERE ID = 0"

# --- headers -----------------------------------------------------------
sameh "header EXTRACT"            "SELECT EXTRACT(YEAR FROM D) FROM T WHERE ID = 1"
sameh "header CURRENT_DATE"       "SELECT CURRENT_DATE FROM T WHERE ID = 1"

# --- refusals: wrong parts, wrong types, malformed forms ---------------
# the engine raises -105 at prepare; fire-crab refuses at prepare too
# (generic Dynamic SQL Error - the -105 detail is a noted difference)
for bad in "SELECT EXTRACT(HOUR FROM D) FROM T" \
           "SELECT EXTRACT(YEAR FROM TM) FROM T" \
           "SELECT EXTRACT(YEAR FROM S) FROM T" \
           "SELECT EXTRACT(QUARTER FROM D) FROM T" \
           "SELECT DATE '2024-02-30' FROM T" \
           "SELECT COALESCE(D, TIME '09:00:00') FROM T" \
           "SELECT COALESCE(D, 1) FROM T"; do
    out=$(printf '%s;\n' "$bad" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF [$bad] answered the fallback: [$out]"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*) echo "OK   refused: $bad" ;;
        *) echo "DIFF [$bad] answered [$out] instead of raising"; fail=1 ;;
    esac
done

# --- teeth: the conventions pinned to values, not just compared --------
v=$(printf 'SET HEADING OFF;\nSELECT EXTRACT(WEEKDAY FROM D), EXTRACT(YEARDAY FROM D), EXTRACT(WEEK FROM D) FROM T WHERE ID = 2;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$v" in
    " 5 0 53 ") echo "OK   teeth: 1999-01-01 is weekday 5, yearday 0, ISO week 53 (of 1998)" ;;
    *) echo "DIFF the convention triple gave [$v], want [ 5 0 53 ]"; fail=1 ;;
esac
v=$(printf 'SET HEADING OFF;\nSELECT EXTRACT(SECOND FROM TM) FROM T WHERE ID = 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "12.3456" ]; then
    echo "OK   teeth: SECOND keeps its written fraction at scale -4 (12.3456)"
else
    echo "DIFF SECOND gave [$v], want 12.3456"; fail=1
fi

exit $fail
