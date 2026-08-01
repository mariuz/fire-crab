#!/bin/bash
# TAKING THE INDEX MUST NOT COST MORE THAN IGNORING IT.
#
# Every other gate here asks whether the answer is right. This one asks
# whether the plan was worth executing, because for a while it was not:
# fire-crab executed the index retrieval that it and the engine both
# chose, and past a few hundred rows that retrieval was SEVERAL TIMES
# SLOWER than the natural scan it replaced.
#
#   rows returned |  index  |  scan
#   ------------- | ------- | ------
#            99   |  100 ms | 157 ms
#           499   |  184 ms | 185 ms   <- parity
#           999   |  283 ms | 149 ms
#          4999   | 1132 ms | 152 ms   <- 7.4x slower than ignoring it
#
# The cause was `records_at_in` building the relation's whole
# sequence->page map - a walk of the file and a decode of every data page
# - and `records_for` calling it with a ONE-ELEMENT slice per accepted
# record. O(rows x pages), paid inside the loop.
#
# Why no existing gate saw it: they all run on ~2.5 MB fixtures with a
# few hundred rows, where the map is cheap and the pathology is
# invisible. This gate builds its own 200,000-row database for that
# reason alone.
#
# THE THREE-WAY ORACLE, as everywhere else in the index work: the same
# binary with the feature ON (a per-gate port), the SAME BINARY with
# FC_NO_INDEX=1, and the real engine. A disagreement between the first
# two is the index path's fault by construction - and here the
# comparison is a TIME as well as a row set.
#
#   qa/serve-real-idxcost.sh [port]
#
# Timing in a gate is a real risk: a loaded machine makes it flaky. The
# assertion is therefore a RATIO with generous headroom - the index path
# may not take more than 1.5x the scan - rather than an absolute budget.
# The defect it exists to catch was 7.4x.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4564}"
PORT2=$((PORT + 1))
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-idxcost.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0
srv=""; srv2=""
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; [ -n "$srv2" ] && kill $srv2 2>/dev/null' EXIT

# --- the fixture: big enough for the map to cost something -------------
# 200,000 rows over ~26 MB. Built once and reused, because building it
# takes longer than the whole rest of the gate - but reused only if it is
# actually COMPLETE. An interrupted earlier run leaves a file with the
# table and no rows, and trusting mere existence turns that into a gate
# that fails for its own reasons. So the reuse test is the row count, and
# a short fixture is REBUILT rather than reported.
rows_in() { # <db>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9]+' | head -1
SET HEADING OFF;
SELECT COUNT(*) FROM INNERT;
SQL
}
have=0
[ -f "$DB" ] && have=$(rows_in "$DB")
if [ "${have:-0}" -lt 100000 ]; then
    rm -f "$DB"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE INNERT (K INTEGER, V VARCHAR(40));
COMMIT;
-- a cross join, not a recursive CTE: the CTE form hits Firebird's
-- 1024-deep recursion limit long before 200,000 rows
INSERT INTO INNERT
  SELECT ROW_NUMBER() OVER (), 'row-' || ROW_NUMBER() OVER ()
    FROM RDB\$TYPES A, RDB\$TYPES B, RDB\$TYPES C ROWS 200000;
COMMIT;
CREATE INDEX IDX_INNERT_K ON INNERT (K);
COMMIT;
EOF
fi
chmod 666 "$DB"

n=$(rows_in "$DB")
if [ "${n:-0}" -lt 100000 ]; then
    echo "FAIL fixture has only ${n:-0} rows after a rebuild - the pathology is invisible below ~100k"
    exit 1
fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-idxcost.log 2>&1 &
srv=$!
FC_NO_INDEX=1 "$FCWIRE" serve "127.0.0.1:$PORT2" "$U" "$P" >>/tmp/fc-serve-idxcost.log 2>&1 &
srv2=$!
i=0; while [ $i -lt 30 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null \
        && nc -z 127.0.0.1 "$PORT2" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
kill -0 $srv2 2>/dev/null || { echo "FAIL the FC_NO_INDEX twin is not running - port $PORT2 in use?"; exit 1; }

cat > "$D/fc-idxcost.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3], q=process.argv[4];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 // warm first, measure second: the first statement pays for the
 // attachment's own setup and would swamp the number being compared
 d.query(q,[],()=>{
  const t=Date.now();
  d.query(q,[],(e2,r)=>{
   if(e2){console.log('ERR '+e2.message);d.detach();return}
   const crc=require('crypto').createHash('md5')
     .update(r.map(x=>Object.values(x).join('|')).join('\n')).digest('hex');
   console.log(`${r.length} ${Date.now()-t} ${crc}`);
   d.detach();
  });
 });
});
EOF

# --- the checks: rows identical three ways, and the index not slower ---
for lim in 100 1000 5000 20000; do
    ran=$((ran + 1))
    q="SELECT V FROM INNERT WHERE K < $lim ORDER BY K"
    a=$(timeout 120 node "$D/fc-idxcost.js" "$PORT" "$DB" "$q" 2>&1)
    b=$(timeout 120 node "$D/fc-idxcost.js" "$PORT2" "$DB" "$q" 2>&1)
    set -- $a; ai=${1:-0}; at=${2:-0}; ac=${3:-x}
    set -- $b; bi=${1:-0}; bt=${2:-0}; bc=${3:-y}
    # 1. the SAME ROWS with the index and without it. This is the
    #    three-way oracle's sharp edge: the two servers are the same
    #    binary, so a difference here is the index path's fault and
    #    nothing else's.
    if [ "$ac" != "$bc" ] || [ "$ai" != "$bi" ]; then
        echo "DIFF K < $lim: index and FC_NO_INDEX disagree ($ai rows/$ac vs $bi rows/$bc)"
        fail=1
        continue
    fi
    # 2. and the same rows as the ENGINE, so "both wrong" cannot pass
    en=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" <<SQL 2>&1 | grep -c .
SET HEADING OFF;
$q;
SQL
)
    if [ "$en" != "$ai" ]; then
        echo "DIFF K < $lim: fire-crab returned $ai rows, the engine $en"
        fail=1
        continue
    fi
    # 3. THE COST. A ratio, not a budget - an absolute millisecond bound
    #    would be a gate that fails when the machine is busy.
    if [ "$bt" -gt 0 ] && [ $((at * 100)) -gt $((bt * 150)) ]; then
        echo "DIFF K < $lim: the INDEX path cost ${at}ms against ${bt}ms for the scan"
        echo "     (over 1.5x - the map is being rebuilt per row again?)"
        fail=1
    else
        echo "OK   K < $lim: $ai rows, index ${at}ms vs scan ${bt}ms"
    fi
done

# --- a point lookup must stay far cheaper than a scan ------------------
# The shape the index exists for. If the per-row rebuild ever returns,
# this is where it shows first and largest.
ran=$((ran + 1))
q="SELECT V FROM INNERT WHERE K = 12345"
a=$(timeout 120 node "$D/fc-idxcost.js" "$PORT" "$DB" "$q" 2>&1)
b=$(timeout 120 node "$D/fc-idxcost.js" "$PORT2" "$DB" "$q" 2>&1)
set -- $a; ai=${1:-0}; at=${2:-0}
set -- $b; bi=${1:-0}; bt=${2:-0}
if [ "$ai" != "1" ] || [ "$bi" != "1" ]; then
    echo "DIFF point lookup returned $ai (index) / $bi (scan) rows, expected 1 each"
    fail=1
elif [ "$bt" -gt 0 ] && [ $((at * 100)) -gt $((bt * 50)) ]; then
    echo "DIFF a point lookup cost ${at}ms against ${bt}ms for a full scan - no better than half"
    fail=1
else
    echo "OK   point lookup: index ${at}ms vs scan ${bt}ms"
fi

rm -f "$D/fc-idxcost.js"
if [ "$ran" -lt 5 ]; then
    echo "DIFF only $ran checks ran (expected at least 5) - did one silently skip?"
    fail=1
fi
exit $fail
