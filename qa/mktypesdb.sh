#!/bin/bash
# Build the WIRETYPES SCRATCH DATABASE that qa/serve-real-types.sh expects,
# and gbak-restore a clean copy of it.
#
# That gate checks the one thing only a typed client can see: fire-crab
# describes and encodes every column type in the ENGINE'S OWN wire form -
# SMALLINT/INTEGER/BIGINT natively rather than coerced to BIGINT, scaled
# numerics as raw integers with the scale in the DESCRIBE (the client
# divides - that is the engine's contract, and getting it wrong moves the
# decimal point rather than raising), floats as IEEE bytes, temporals as
# raw day / 1e-4-second units, BOOLEAN as an XDR int slot. It has been
# unrunnable for want of this database, which is the same way the join
# gates were lost before qa/mkjoindb.sh - a gate nobody can run is a gate
# that stops telling the truth.
#
# The one table is TY, and every value in it is chosen against a
# CANONICALISATION rule the gate has to obey, because the two sides speak
# different languages (JS values vs isql text):
#
#   ID     - INTEGER, the sort key; rows 1..4
#   SI     - SMALLINT at BOTH EXTREMES (-32768, 32767): a width coerced to
#            BIGINT still round-trips, so only the extremes of the NARROW
#            type prove the describe announced SHORT
#   BI     - BIGINT, kept inside 2^53 because node decodes it to a JS
#            number; the gate would otherwise measure the driver
#   N92    - NUMERIC(9,2)  stored as LONG
#   N42    - NUMERIC(4,2)  stored as SHORT  (one NULL: it sorts FIRST)
#   D154   - DECIMAL(15,4) stored as INT64
#            no scaled value ends in a ZERO decimal digit - a JS number
#            drops it and 12.30 would print 12.3 on one side only
#   F, DP  - FLOAT and DOUBLE PRECISION, values exactly representable in
#            binary (halves and quarters), so neither renderer rounds
#   DT     - DATE, including 1858-11-17, the MJD EPOCH (day 0) - the value
#            an off-by-one in the day conversion cannot hide in; two rows
#            SHARE a date and one is NULL, for the GROUP BY check
#   TM     - TIME at whole MILLISECONDS (JS Date resolution; the wire
#            carries 1/10000 s) and never MIDNIGHT, which the gate's
#            formatter reads as a DATE sentinel; one NULL, so COUNT(TM)
#            is not COUNT(*)
#   TS     - TIMESTAMP, never midnight and never 1970-01-01 (the other
#            sentinel), all distinct so ORDER BY ... DESC has one answer
#   B, VC  - BOOLEAN and VARCHAR, each with a NULL
#
#   qa/mktypesdb.sh [path]      (default /tmp/fbhandson/wiretypes.fdb)
#
# Prints the path of the CLEAN restored copy, which is what the gate
# wants: a gbak round trip normalises the file's page state, so what it
# reads is not one workspace's history.

set -u
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
SRC="${1:-/tmp/fbhandson/wiretypes.fdb}"
DIR=$(dirname "$SRC")
BASE=$(basename "$SRC" .fdb)
FBK="$DIR/$BASE.fbk"
CLEAN="$DIR/${BASE}_clean.fdb"

mkdir -p "$DIR"
rm -f "$SRC" "$FBK" "$CLEAN"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create" >&2; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE TY (
  ID   INTEGER NOT NULL PRIMARY KEY,
  SI   SMALLINT,
  BI   BIGINT,
  N92  NUMERIC(9,2),
  N42  NUMERIC(4,2),
  D154 DECIMAL(15,4),
  F    FLOAT,
  DP   DOUBLE PRECISION,
  DT   DATE,
  TM   TIME,
  TS   TIMESTAMP,
  B    BOOLEAN,
  VC   VARCHAR(20)
);
COMMIT;

INSERT INTO TY VALUES (1, -32768, -9876543210, 12.34, 9.51, 12.3456,
  1.5, 1234.5, '1858-11-17', '01:02:03.123', '2021-06-15 08:30:45.123',
  TRUE, 'alpha');
INSERT INTO TY VALUES (2, 32767, 1234567890123, -5.67, 12.34, -7.5001,
  -2.25, -0.75, '2020-03-15', '23:59:59.999', '1999-12-31 23:59:59.999',
  FALSE, 'beta gamma');
INSERT INTO TY VALUES (3, 0, 0, 1234.56, NULL, 99.9999,
  0.5, 2.5, '2020-03-15', NULL, '2000-01-01 12:00:00.500',
  NULL, NULL);
INSERT INTO TY VALUES (4, NULL, NULL, NULL, -1.23, NULL,
  NULL, NULL, NULL, '12:00:00.001', '2021-06-15 08:30:45.124',
  TRUE, 'z');
COMMIT;
EOF

"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$FBK" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$CLEAN" >/dev/null 2>&1 || {
    echo "FAIL gbak round trip" >&2; exit 1; }
chmod 666 "$CLEAN" 2>/dev/null

# teeth: the properties the checks are built on must actually hold, and
# each of these is a property some check would silently stop testing
check=$("$ISQL" -q -b -user "$U" -pas "$P" "$CLEAN" <<'EOF' 2>&1
SET HEADING OFF;
SELECT COUNT(*) FROM TY;
SELECT MIN(SI) FROM TY;
SELECT MAX(SI) FROM TY;
SELECT COUNT(TM) FROM TY;
SELECT COUNT(*) FROM TY WHERE N42 IS NULL;
SELECT COUNT(*) FROM TY WHERE DT = '2020-03-15';
SELECT COUNT(DISTINCT TS) FROM TY;
SELECT COUNT(*) FROM TY WHERE DT = '1858-11-17';
EOF
)
set -- $check
if [ "$1" = "4" ] && [ "$2" = "-32768" ] && [ "$3" = "32767" ] && [ "$4" = "3" ] \
   && [ "$5" = "1" ] && [ "$6" = "2" ] && [ "$7" = "4" ] && [ "$8" = "1" ]; then
    echo "$CLEAN"
else
    echo "FAIL fixture properties: rows=$1 si_min=$2 si_max=$3 times=$4 null_n42=$5 shared_date=$6 distinct_ts=$7 epoch_day=$8" >&2
    exit 1
fi
