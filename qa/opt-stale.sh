#!/bin/bash
# THE STALE-STATISTICS REGION, measured. Statistics that are NON-ZERO but
# WRONG - snapshotted by SET STATISTICS while the table was small, then
# the table grown a hundredfold - take the engine's ordinary costing path
# with a figure that no longer describes the data
# (`useDefaultSelectivity == false`). The roadmap called this region
# "entirely unmeasured"; this gate is the fixture family and the
# measurement.
#
# FIXTURE: S loads 100 rows with 10 distinct keys, SET STATISTICS
# snapshots selectivity 0.1, then 10,000 all-distinct rows land WITHOUT a
# re-analyse - the stored figure claims one key in ten where the truth is
# one in ten thousand, at 100x the cardinality it was measured against.
#
# Ten statements walk the decision surface on that fixture; fcopt must
# print the engine's own PLANONLY line. All ten agree - retrieval, range,
# OR union, navigation, the unfiltered join AND the filtered-driver join
# all read the stale figure the way the engine reads it.
#
# The FILTERED-DRIVER join was the region's one named gap when it was
# first measured: the engine kept `JOIN (B NATURAL, S INDEX)` at every
# stale selectivity while fcopt flipped to HASH. The missing arithmetic
# was the DRIVER's own filter: the engine's estimateSelectivity prices
# `B.BV = 3` over 200 rows at ONE row (unindexed-equality factor 0.001,
# floored by the small-table adjustment at 1/cardinality), so the loop
# behind that driver costs one probe however stale the inner's figure is
# - which is what makes its loop nearly independent of the stale figure.
# `stream_filter_selectivity` converts exactly that; the CONTROL at the
# end brackets the arithmetic from the fresh side too.
#
#   qa/opt-stale.sh

set -u
FCOPT="${FCOPT:-$(dirname "$0")/../target/release/fcopt}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-optstale.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE S (ID INTEGER, K INTEGER);
CREATE TABLE B (BK INTEGER, BV INTEGER);
CREATE INDEX IDX_S_K ON S (K);
CREATE INDEX IDX_B_BK ON B (BK);
COMMIT;
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 100) DO BEGIN I = I + 1; INSERT INTO S VALUES (:I, MOD(:I,10)); END
END^
SET TERM ;^
COMMIT;
SET STATISTICS INDEX IDX_S_K;
COMMIT;
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 100; BEGIN
  WHILE (I < 10100) DO BEGIN I = I + 1; INSERT INTO S VALUES (:I, :I); END
  I = 0;
  WHILE (I < 200) DO BEGIN I = I + 1; INSERT INTO B VALUES (:I, :I); END
END^
SET TERM ;^
COMMIT;
EOF
chmod 666 "$DB"

fail=0; ran=0
eng() { printf 'SET PLANONLY ON;\n%s;\n' "$1" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 | grep "^PLAN" | head -1; }
fcp() { "$FCOPT" plan "$DB" "$1" 2>&1 | head -1; }
same() { # <sql> - fcopt must print the engine's line
    ran=$((ran + 1))
    want=$(eng "$1"); got=$(fcp "$1")
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
        echo "OK   $1"
        echo "     $got"
    else
        echo "DIFF $1"
        echo "     engine: $want"
        echo "     fcopt:  $got"
        fail=1
    fi
}

# the stale figure is really stored and really wrong
ran=$((ran + 1))
stat=$(printf 'SET HEADING OFF;\nSELECT RDB$STATISTICS FROM RDB$INDICES WHERE RDB$INDEX_NAME='"'"'IDX_S_K'"'"';\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 | tr -d ' \n')
case "$stat" in
    0.1*) echo "OK   the stored selectivity is the stale 0.1 (truth ~0.0001)" ;;
    *) echo "DIFF stored selectivity [$stat] - the fixture did not go stale"; fail=1 ;;
esac

# --- nine cells of the decision surface, stale figure in hand ----------
same "SELECT * FROM S WHERE K = 5"
same "SELECT * FROM S WHERE K > 9000"
same "SELECT * FROM S WHERE K BETWEEN 3 AND 7"
same "SELECT * FROM S WHERE K = 5 OR K = 7"
same "SELECT * FROM S WHERE ID = 5"
same "SELECT * FROM S ORDER BY K"
same "SELECT * FROM S WHERE K = 5 ORDER BY K"
same "SELECT FIRST 5 K FROM S ORDER BY K"
same "SELECT * FROM S JOIN B ON S.K = B.BK"

# --- the tenth cell: the FILTERED-DRIVER join --------------------------
# This was the region's one named gap - the engine kept
# JOIN (B NATURAL, S INDEX) at every stale selectivity while fcopt
# flipped to HASH - until the driver's FILTER entered the arithmetic:
# `B.BV = 3` over 200 rows estimates ONE row (the engine's
# estimateSelectivity: unindexed-equality factor 0.001, floored by the
# small-table adjustment at 1/cardinality), so the loop behind it costs
# one probe however stale the inner's figure is. With
# stream_filter_selectivity converted, the cell agrees at every stale
# selectivity probed (0.5 through 0.01).
JQ="SELECT * FROM B JOIN S ON S.K = B.BK WHERE B.BV = 3"
same "$JQ"

# --- the CONTROL: the same database, statistics refreshed --------------
# the same join with a fresh figure keeps agreeing - the two regimes
# bracket the arithmetic from both sides.
cp "$DB" "$D/fc-optstale-fresh.fdb"; chmod 666 "$D/fc-optstale-fresh.fdb"
printf 'SET STATISTICS INDEX IDX_S_K;\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-optstale-fresh.fdb" >/dev/null 2>&1
ran=$((ran + 1))
ef=$(printf 'SET PLANONLY ON;\n%s;\n' "$JQ" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-optstale-fresh.fdb" 2>&1 | grep "^PLAN" | head -1)
ff=$("$FCOPT" plan "$D/fc-optstale-fresh.fdb" "$JQ" 2>&1 | head -1)
if [ -n "$ef" ] && [ "$ef" = "$ff" ]; then
    echo "OK   control: with FRESH statistics the same join agrees"
    echo "     $ff"
else
    echo "DIFF control: fresh statistics should agree - engine [$ef], fcopt [$ff]"
    fail=1
fi

rm -f "$D/fc-optstale-fresh.fdb"
if [ "$ran" -lt 12 ]; then
    echo "DIFF only $ran checks ran (expected at least 12) - did one silently skip?"
    fail=1
fi
exit $fail
