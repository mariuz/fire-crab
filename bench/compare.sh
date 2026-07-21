#!/bin/sh
# Benchmark the Rust and C++ implementations on the same work:
#
#  1. header decode: fcstat header vs gstat -h (mostly process
#     startup + one page read on both sides - reported for context,
#     not as a meaningful difference)
#  2. full-file page census: fcstat's in-memory census throughput
#     (fcstat bench-census), the first real converted workload
#
#   bench/compare.sh /path/to/db.fdb [iterations]
#
# Honest caveats, spelled out because benchmarks invite over-reading:
# gstat -h does far more than decode 10 fields (attaches through parts
# of the engine stack), so (1) compares tools, not algorithms; and (2)
# has no exact gstat equivalent - gstat -d walks pages via the engine
# with different work per page. These numbers bound the conversion's
# I/O-free decode throughput; they do not claim "Rust is N x faster
# than the engine".

set -u
GSTAT="${GSTAT:-gstat}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
DB="${1:?usage: compare.sh db.fdb [iters]}"
ITERS="${2:-50}"

echo "== tool wall clock: header page (single run, includes startup) =="
for tool in "$GSTAT -h" "$FCSTAT header"; do
    start=$(date +%s%N)
    $tool "$DB" > /dev/null
    end=$(date +%s%N)
    printf '%-16s %6.1f ms\n' "$(echo "$tool" | awk '{print $1}' | xargs basename)" \
        "$(( (end - start) / 1000000 )).$(( ((end - start) / 100000) % 10 ))"
done

echo
echo "== converted workload: full-file page census (in memory) =="
"$FCSTAT" bench-census "$DB" "$ITERS"
