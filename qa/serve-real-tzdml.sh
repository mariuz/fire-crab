#!/bin/bash
# TIME/TIMESTAMP WITH TIME ZONE values in DML - literals, string CVT,
# cross-type assignment, WHERE and ORDER BY. fire-crab could CREATE tz
# columns and READ engine-written rows but refused every tz VALUE.
#
# The measured engine laws this gate pins:
#   - a tz value stores the UTC instant + a USHORT zone id (offset
#     zones id = minutes + 1439, -14:00..=+14:00; named zones count
#     down from GMT = 65535); the literal's wall clock converts by the
#     zone's displacement
#   - a ZONELESS literal/string into a tz column takes the SESSION
#     zone, permanently; a tz value into a ZONE-LESS column converts
#     to the session's wall time
#   - the CVT string grammar accepts a trailing zone everywhere
#   - comparisons and ORDER BY are UTC-INSTANT (the zone is
#     presentation): the same instant spelled +02:00 / UTC / zoneless
#     matches identically
#   - the 22009 vectors verbatim: `Invalid time zone region: X` and
#     `Invalid time zone offset: X - must use format ...`
#
# Boundaries (recorded): NAMED zones with tzdata rules (Europe/Paris)
# refuse in DML - fire-crab carries the id<->name table but no IANA
# rules, and a wrong instant is worse than a refusal (the UTC family
# and Etc/GMT+-N convert; engine-written named-zone rows still read
# fine - the client renders them). TIME-TZ into a TIMESTAMP column
# (the 2020-01-01 base-date re-anchor law) refuses. EXTRACT/AT TIME
# ZONE stay outside this slice.
#
#   qa/serve-real-tzdml.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4976}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-tzdml-crab.fdb"; B="$D/fc-tzdml-engine.fdb"
LOG="/tmp/fc-serve-tzdml-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE TZT (ID INTEGER, TS TIMESTAMP WITH TIME ZONE, TM TIME WITH TIME ZONE, PTS TIMESTAMP, PT TIME);
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

# --- literals, string CVT, cross-type, UPDATE - one script each way ---
cat > "$D/tz1.sql" <<'SQL'
SET LIST ON;
INSERT INTO TZT (ID, TS, TM) VALUES (1, TIMESTAMP '2024-11-05 23:30:00 +02:00', TIME '00:00:01 UTC');
INSERT INTO TZT (ID, TS, TM) VALUES (2, TIMESTAMP '2024-05-05 10:00:00 -05:30', TIME '10:00:00 +14:00');
INSERT INTO TZT (ID, TS, TM) VALUES (3, TIMESTAMP '2024-05-05 10:00:00', TIME '23:59:59.9999 -00:30');
INSERT INTO TZT (ID, TS, TM) VALUES (4, '2024-08-08 09:00:00 +05:30', '07:07:07 Etc/GMT+5');
INSERT INTO TZT (ID, TS, TM) VALUES (5, '2024-02-29 12:00:00', '06:00:00');
UPDATE TZT SET TS = TIMESTAMP '2020-02-29 00:00:00 GMT' WHERE ID = 3;
UPDATE TZT SET TM = '11:11:11 -07:00' WHERE ID = 5;
-- a tz VALUE into the ZONE-LESS columns converts to the session's wall
INSERT INTO TZT (ID, PTS, PT) VALUES (6, TIMESTAMP '2024-05-05 10:00:00 -05:30', TIME '10:00:00 +02:00');
COMMIT;
SELECT ID, TS, TM, PTS, PT FROM TZT ORDER BY ID;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tz1.sql" 2>&1 | norm; }
check "tz literals + string CVT + zoneless-takes-session + tz-into-plain + UPDATE, byte-identical" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

# --- WHERE is UTC-INSTANT; ORDER BY across zones ---
cat > "$D/tz2.sql" <<'SQL'
SET LIST ON;
SELECT ID FROM TZT WHERE TS = TIMESTAMP '2024-11-05 21:30:00 UTC' ORDER BY ID;
SELECT ID FROM TZT WHERE TS = TIMESTAMP '2024-11-05 21:30:00' ORDER BY ID;
SELECT ID FROM TZT WHERE TS = '2024-11-05 23:30:00 +02:00' ORDER BY ID;
SELECT ID FROM TZT WHERE TS = TIMESTAMP '2024-11-05 16:30:00 -05:00' ORDER BY ID;
SELECT ID FROM TZT WHERE TM > TIME '05:00:00 UTC' ORDER BY ID;
SELECT ID FROM TZT WHERE TS IS NOT NULL ORDER BY TS, ID;
SQL
wof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tz2.sql" 2>&1 | norm; }
check "WHERE compares by UTC instant across spellings; ORDER BY tz column" \
    "$(wof "127.0.0.1/$PORT:$A")" "$(wof "127.0.0.1/$REAL:$B")"

# --- the 22009 vectors, verbatim ---
cat > "$D/tz3.sql" <<'SQL'
INSERT INTO TZT (ID, TS) VALUES (9, TIMESTAMP '2024-05-05 10:00:00 Bad/Zone');
INSERT INTO TZT (ID, TS) VALUES (9, TIMESTAMP '2024-05-05 10:00:00 +15:00');
INSERT INTO TZT (ID, TS) VALUES (9, TIMESTAMP '2024-05-05 10:00:00 +14:01');
INSERT INTO TZT (ID, TS) VALUES (9, '2024-05-05 10:00:00 No/Where');
SQL
eof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tz3.sql" 2>&1 | grep -v "^After line" | norm; }
check "the 22009 vectors: Invalid time zone region / offset, engine-verbatim" \
    "$(eof "127.0.0.1/$PORT:$A")" "$(eof "127.0.0.1/$REAL:$B")"

# --- the review's live-verified catches, pinned differentially ---
cat > "$D/tz4.sql" <<'SQL'
SET LIST ON;
-- inner-sign offset spellings are the engine's 22009 (a '-+2:00'
-- stored a SIGN-FLIPPED instant before the review)
INSERT INTO TZT (ID, TS) VALUES (10, TIMESTAMP '2024-01-01 10:00:00 ++2:00');
INSERT INTO TZT (ID, TS) VALUES (11, TIMESTAMP '2024-01-01 10:00:00 -+2:00');
INSERT INTO TZT (ID, TS) VALUES (12, TIMESTAMP '2024-01-01 10:00:00 +02:+5');
INSERT INTO TZT (ID, TS, TM) VALUES (13, TIMESTAMP '2024-05-05 12:00:00 +02:00', TIME '05:00:00 +02:00');
INSERT INTO TZT (ID, TS, TM) VALUES (14, TIMESTAMP '2024-05-05 10:00:00 UTC', TIME '03:00:00 UTC');
COMMIT;
-- tz differences: UTC-instant, TIME pair at -4, tz-minus-plain via session
SELECT TS - TS D0, TM - TM T0 FROM TZT WHERE ID = 13;
SELECT ID FROM TZT WHERE ID IN (13, 14) AND TS - TS = 0 ORDER BY ID;
-- CAST of a zone-tailed STRING to plain temporals session-converts
SELECT CAST('2024-05-05 10:00:00 +02:00' AS TIMESTAMP) CP FROM RDB$DATABASE;
SELECT CAST('10:00:00 -03:00' AS TIME) CT FROM RDB$DATABASE;
-- a stored instant past the calendar raises the engine's 22008 at READ
INSERT INTO TZT (ID, TS) VALUES (70, '9999-12-31 23:00:00 -02:00');
SELECT ID, TS FROM TZT WHERE ID = 70;
SQL
rvf() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tz4.sql" 2>&1 | grep -v "^After line" | norm; }
check "review catches: inner-sign 22009s, tz differences, zone-tailed CAST, the 22008 read range" \
    "$(rvf "127.0.0.1/$PORT:$A")" "$(rvf "127.0.0.1/$REAL:$B")"

# --- a DEDUP over tz keys refuses (fc-only pin): the engine's tie
# --- representative is an unstable sort artifact - it flipped between
# --- largest and smallest zone id under a WHERE during review - and a
# --- wrong representative is a wrong answer ---
ran=$((ran + 1))
dd=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT TS, COUNT(*) C FROM TZT GROUP BY TS;
SELECT DISTINCT TS FROM TZT;
SELECT TM FROM TZT WHERE ID = 13 UNION SELECT TM FROM TZT WHERE ID = 14;
SQL
)
case "$dd" in *"Dynamic SQL Error"*"Dynamic SQL Error"*"Dynamic SQL Error"*)
    echo "OK   GROUP BY / DISTINCT / UNION over tz keys refuse (unstable engine tie artifact)";;
    *) echo "DIFF tz-dedup refusals: [$dd]"; fail=1;; esac

# --- the ENGINE reads what fc stored (ids + instants are real) ---
ran=$((ran + 1))
er=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT ID, TS, TM FROM TZT WHERE ID IN (1, 2, 4) ORDER BY ID;
INSERT INTO TZT (ID, TS) VALUES (7, TIMESTAMP '2024-01-01 00:00:00 +03:00');
SELECT ID FROM TZT WHERE TS = TIMESTAMP '2023-12-31 21:00:00 UTC';
SQL
)
case "$er" in *"2024-11-05 23:30:00.0000 +02:00"*"07:07:07.0000 Etc/GMT+5"*"ID 7"*)
    echo "OK   the ENGINE reads fc's stored tz values and matches instants over them";;
    *) echo "DIFF engine-reads-fc: [$er]"; fail=1;; esac

# --- boundary: a NAMED zone with tzdata rules refuses (never a wrong
# --- instant) - fc-only pin; the engine stores it ---
ran=$((ran + 1))
br=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL' | norm
INSERT INTO TZT (ID, TS) VALUES (9, TIMESTAMP '2024-05-05 10:00:00 Europe/Paris');
SET LIST ON;
SELECT COUNT(*) N9 FROM TZT WHERE ID = 9;
SQL
)
case "$br" in *"Dynamic SQL Error"*"N9 0"*)
    echo "OK   a ruled NAMED zone refuses in DML (no tzdata - never a guessed instant)";;
    *) echo "DIFF named-zone boundary: [$br]"; fail=1;; esac

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
