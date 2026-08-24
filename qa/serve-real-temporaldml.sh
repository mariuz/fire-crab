#!/bin/bash
# Temporal values in DML - and the engine's WHOLE string-to-datetime
# grammar. Until this slice fire-crab could not put a DATE/TIME/TIMESTAMP
# value into a column through its own wire in ANY form (typed literal,
# string, CAST, CURRENT_DATE - every one refused; every temporal fixture
# had to be engine-built), and its text->temporal conversion knew ISO
# forms only.
#
# Now, all measured against the live engine:
#   - INSERT ... VALUES takes DATE/TIME/TIMESTAMP literals, strings,
#     CAST(...) constants, CURRENT_DATE / CURRENT_TIME / CURRENT_TIMESTAMP
#     (the WITH TIME ZONE clocks landing session-local) and LOCALTIME /
#     LOCALTIMESTAMP; UPDATE SET takes the same through both its tiers.
#   - the conversion grammar is CVT_string_to_datetime ported arm for arm:
#     the three date components in any order (a 4-digit lead is Y-M-D, a
#     leading English month M-D-Y, a middle one D-M-Y, a `.` separator
#     D-M-Y, else M-D-Y), one CONSISTENT separator from `/ - .` or spaces,
#     month names by >=3-letter prefix, 2-digit years in the 50-year
#     window, a missing year defaulting to the current one, the specials
#     NOW/TODAY/TOMORROW/YESTERDAY (string coercion only - a typed
#     literal refuses them, as the engine does), times as HH:MM[:SS[.ffff]]
#     with minutes required and at most 4 fraction digits, impossible
#     dates by round-trip, years 1..9999. One grammar everywhere: DML
#     strings, CAST from text, a text literal against a temporal column.
#   - the cross-type lattice: TIMESTAMP truncates into DATE/TIME, DATE is
#     midnight of a TIMESTAMP, TIME lands dated TODAY; TIME into DATE and
#     DATE into TIME refuse.
#   - INSERT ... SELECT re-renders rows as VALUES text, so temporal
#     columns ride it now too.
#
# A one-token CONSTANT expression that folds to a temporal rides the new
# VALUES arm too - CASE WHEN .. THEN DATE '..' END, COALESCE(NULL, DATE
# '..') - and a temporal value lands in a TEXT column as its rendered
# form, both as the engine answers.
#
# Boundaries (recorded): a bad string refuses with fc's GENERIC vector
# where the engine spells 22018 with the string (the shape every fc
# INSERT conversion already has - 'abc' into an INTEGER is the same; the
# CAST path is typed, and junk after a time fraction draws the engine's
# 22009 invalid-zone where fc says 22018); a trailing TIMEZONE in a
# string ('... 10:00 America/New_York') refuses where the engine converts
# it; a PARENTHESIZED value `((DATE '..'))` and arithmetic (`DATE '..' +
# 1`) stay refused - the pre-existing constant-expression VALUES class;
# TIME/TIMESTAMP WITH TIME ZONE columns still take no DML values.
#
#   qa/serve-real-temporaldml.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4959}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-tdml-crab.fdb"; B="$D/fc-tdml-engine.fdb"
LOG="/tmp/fc-serve-tdml-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

# --- the INSERT battery: every accepted form, both servers' own wire ---
cat > "$D/tfix.sql" <<'SQL'
CREATE TABLE TT (ID INTEGER, D DATE, T TIME, TS TIMESTAMP, V VARCHAR(10));
CREATE INDEX TTD ON TT (D);
COMMIT;
INSERT INTO TT VALUES (1, DATE '2020-01-15', TIME '12:34:56.7890', TIMESTAMP '2020-01-15 12:34:56', 'a');
INSERT INTO TT VALUES (2, '2021-03-02', '7:08', '2021-03-02 07:08:09.1200', 'b');
INSERT INTO TT (ID, D) VALUES (3, CAST('2022-05-06' AS DATE));
INSERT INTO TT (ID, D) VALUES (4, '15-JAN-2020');
INSERT INTO TT (ID, D) VALUES (5, '5.6.2020');
INSERT INTO TT (ID, D) VALUES (6, '03/04/2020');
INSERT INTO TT (ID, TS) VALUES (7, '2020-01-15');
INSERT INTO TT (ID, D) VALUES (8, TIMESTAMP '2020-05-06 12:00:00');
INSERT INTO TT (ID, T) VALUES (9, TIMESTAMP '2020-01-15 10:11:12');
INSERT INTO TT (ID, TS) VALUES (10, DATE '2020-01-15');
INSERT INTO TT (ID, D) VALUES (11, '5-6-96');
INSERT INTO TT (ID, D) VALUES (12, '15 JANUARY 2020');
INSERT INTO TT (ID, D) VALUES (13, 'JANU 15 2020');
INSERT INTO TT (ID, D) VALUES (14, '29.02.2024');
INSERT INTO TT (ID, T) VALUES (15, '23:59:59.9999');
INSERT INTO TT (ID, TS) VALUES (16, '2020-1-5 7:00');
INSERT INTO TT (ID, D) VALUES (17, DATE '7-8');
INSERT INTO TT (ID, V) VALUES (18, DATE '2020-01-15');
INSERT INTO TT (ID, D) VALUES (19, CASE WHEN 1=1 THEN DATE '2020-03-03' ELSE NULL END);
INSERT INTO TT (ID, D) VALUES (30, CAST(NULL AS DATE));
INSERT INTO TT (ID, D) VALUES (31, 'TODAY.');
COMMIT;
UPDATE TT SET D = '16-JAN-2020' WHERE ID = 4;
UPDATE TT SET T = '0:00:00.0001', TS = TIMESTAMP '1999-12-31 23:59:59' WHERE ID = 2;
UPDATE TT SET D = CAST('2023-07-08' AS DATE) WHERE ID = 5;
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/tfix.sql" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/tfix.sql" >/dev/null 2>&1

cat > "$D/tsel.sql" <<'SQL'
SET LIST ON;
SELECT ID, D, T, TS, V FROM TT ORDER BY ID;
SQL
sof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tsel.sql" 2>&1 | norm; }
check "every INSERT/UPDATE form stores what the engine stores (typed literals, the whole string grammar, CAST, cross-type)" \
    "$(sof "127.0.0.1/$PORT:$A")" "$(sof "127.0.0.1/$REAL:$B")"

# --- the string grammar on the WHERE side, and the indexed lookup ---
cat > "$D/twhere.sql" <<'SQL'
SET LIST ON;
SELECT COUNT(*) W1 FROM TT WHERE D = '16-JAN-2020';
SELECT COUNT(*) W2 FROM TT WHERE D = '2020/03/04';
SELECT COUNT(*) W3 FROM TT WHERE D > '2020-02-01';
SELECT COUNT(*) W4 FROM TT WHERE TS = '2020-01-15';
SELECT COUNT(*) W5 FROM TT WHERE T = '23:59:59.9999';
SELECT COUNT(*) W6 FROM TT WHERE D = '29-FEB-2024';
SELECT COUNT(*) W7 FROM TT WHERE ID = 30 AND D IS NULL;
SELECT COUNT(*) W8 FROM TT WHERE ID = 31 AND D = 'TODAY';
SQL
wof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/twhere.sql" 2>&1 | norm; }
check "the grammar reaches comparisons (month names, slashes, a date-only string against a TIMESTAMP), the DATE index included" \
    "$(wof "127.0.0.1/$PORT:$A")" "$(wof "127.0.0.1/$REAL:$B")"

# --- the clocks and the specials: compared by PREDICATE, not by instant ---
cat > "$D/tclk.sql" <<'SQL'
INSERT INTO TT (ID, D) VALUES (20, CURRENT_DATE);
INSERT INTO TT (ID, T) VALUES (21, CURRENT_TIME);
INSERT INTO TT (ID, TS) VALUES (22, CURRENT_TIMESTAMP);
INSERT INTO TT (ID, T) VALUES (23, LOCALTIME);
INSERT INTO TT (ID, TS) VALUES (24, LOCALTIMESTAMP);
INSERT INTO TT (ID, D) VALUES (25, 'TODAY');
INSERT INTO TT (ID, D) VALUES (26, 'TOMORROW');
INSERT INTO TT (ID, D) VALUES (27, 'yesterday');
INSERT INTO TT (ID, TS) VALUES (28, 'NOW');
COMMIT;
UPDATE TT SET T = CURRENT_TIME, TS = CURRENT_TIMESTAMP WHERE ID = 20;
COMMIT;
SET LIST ON;
SELECT COUNT(*) C1 FROM TT WHERE ID = 20 AND D = CURRENT_DATE AND T IS NOT NULL AND TS >= CURRENT_DATE;
SELECT COUNT(*) C2 FROM TT WHERE ID IN (21, 22, 23, 24) AND (T IS NOT NULL OR TS >= CURRENT_DATE);
SELECT COUNT(*) C3 FROM TT WHERE ID = 25 AND D = 'TODAY';
SELECT COUNT(*) C4 FROM TT WHERE ID = 26 AND D = 'TOMORROW';
SELECT COUNT(*) C5 FROM TT WHERE ID = 27 AND D = 'YESTERDAY';
SELECT COUNT(*) C6 FROM TT WHERE ID = 28 AND TS >= CURRENT_DATE;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tclk.sql" 2>&1 | norm; }
check "the clocks (WITH TIME ZONE ones landing session-local) and the specials, in INSERT, UPDATE and WHERE" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

# --- INSERT ... SELECT carries temporal columns (the re-rendered row) ---
cat > "$D/tinssel.sql" <<'SQL'
CREATE TABLE TC (ID INTEGER, D DATE, T TIME, TS TIMESTAMP);
COMMIT;
INSERT INTO TC SELECT ID, D, T, TS FROM TT WHERE ID <= 12;
COMMIT;
SET LIST ON;
SELECT ID, D, T, TS FROM TC ORDER BY ID;
SQL
iof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tinssel.sql" 2>&1 | norm; }
check "INSERT ... SELECT carries the temporal columns" \
    "$(iof "127.0.0.1/$PORT:$A")" "$(iof "127.0.0.1/$REAL:$B")"

# --- the ENGINE reads fc's file: the stored bytes are the engine's ---
ran=$((ran + 1))
eng=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT ID, D, T, TS FROM TT WHERE ID IN (1, 2, 5, 12, 14, 16) ORDER BY ID;
SQL
)
crab=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT ID, D, T, TS FROM TT WHERE ID IN (1, 2, 5, 12, 14, 16) ORDER BY ID;
SQL
)
if [ -n "$eng" ] && [ "$eng" = "$crab" ]; then echo "OK   the engine reads fc's stored temporal bytes, line for line"; else
    echo "DIFF engine-reads-fc: [$eng] vs [$crab]"; fail=1; fi

# --- refusals: the engine's 22018 shapes refuse on fc too (fc's generic
# --- vector - the recorded boundary), and a typed literal takes no specials
bref() { ran=$((ran + 1))
    local c
    c=$(echo "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$c" in *"Dynamic SQL Error"*|*"conversion error"*) echo "OK   $1 (refused)";;
        *) echo "DIFF $1 answered: [$c]"; fail=1;; esac
}
bref "an impossible date refuses" "INSERT INTO TT (ID, D) VALUES (90, '2020-02-30');"
bref "a five-digit fraction refuses" "INSERT INTO TT (ID, T) VALUES (91, '12:34:56.78901');"
bref "junk refuses" "INSERT INTO TT (ID, D) VALUES (92, 'nonsense');"
bref "mixed separators refuse" "INSERT INTO TT (ID, D) VALUES (93, '5/6.2020');"
bref "a time portion refuses in a DATE" "INSERT INTO TT (ID, D) VALUES (94, '2020-01-15 10:00');"
bref "an hour without minutes refuses" "INSERT INTO TT (ID, TS) VALUES (95, '2020-1-5 7');"
bref "a TIME literal into a DATE refuses" "INSERT INTO TT (ID, D) VALUES (96, TIME '10:00:00');"
bref "a DATE literal into a TIME refuses" "INSERT INTO TT (ID, T) VALUES (97, DATE '2020-01-15');"
bref "a typed literal takes no specials" "INSERT INTO TT (ID, D) VALUES (98, DATE 'TODAY');"
bref "a trailing timezone refuses (recorded: the engine converts it)" "INSERT INTO TT (ID, TS) VALUES (99, '2020-01-15 10:00 America/New_York');"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file (the DATE index included)"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
