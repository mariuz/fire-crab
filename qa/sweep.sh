#!/bin/bash
# RUN THE WHOLE serve-real SUITE, several gates at a time.
#
# A gate is mostly WAITING - on its own fcwire, on the engine at 3050,
# on fsync - so the suite is latency-bound long before it is CPU-bound,
# and running a few at once shortens the wall clock well past the core
# count. What makes that safe is that every gate already takes its PORT
# as `$1` and builds its own scratch databases; this runner hands each
# one a private port so no two ever meet.
#
#   qa/sweep.sh [-j N] [-o LOG] [PATTERN...]
#
#     -j N        gates at a time (default 4)
#     -o LOG      where the combined log goes (default /tmp/fc-sweep.log)
#     PATTERN...  run only gates whose name contains one of these
#
# The log keeps the SERIAL format - `=== <gate>`, the gate's own lines,
# `--- rc=<n> <gate>` - because everything that reads a sweep (and every
# habit built around one) greps for those. Each gate writes to its own
# file and is appended whole when it finishes, so nothing interleaves.
#
# WHAT STAYS SERIAL, and why - see SERIAL below. Two kinds: gates that
# MEASURE TIME or contention (`idxcost` compares an index plan's
# milliseconds against a scan's, and a box running four gates at once
# made the index side look 2x SLOWER than the scan - it passes alone at
# the same load average, so what it was reporting was the sweep) (a parallel sweep makes a loaded box, and a
# gate that waits on a lock or compares a service's line-buffered output
# starts reporting the load instead of the server), and the four gates
# that share scratch-database NAMES with another gate. Those run alone,
# after the parallel phase.
set -u
cd "$(dirname "$0")/.."
export PATH="${PATH}:/opt/firebird/bin"
export NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"
JOBS=4
LOG=/tmp/fc-sweep.log
# LAST RUN'S TIMINGS, kept in the repo, and used to start the SLOW gates
# FIRST (longest-processing-time-first, the classic schedule). Unknown
# gates sort first, so a NEW gate is never left to the tail.
#
# MEASURED, so nobody re-derives it: on this two-core box the ordering
# buys NOTHING. Arrival order and LPT both ran the full suite in 1659s
# (340 gates, 9321 checks). LPT pays only when the TAIL dominates - one
# long gate still running while cores idle - and at -j 4 the cores are
# already saturated, so the wall clock is total work over parallelism
# and no reordering changes total work. (-j 6 and -j 8 measured 30s and
# 29s against -j 4's 31s on a subset: the same ceiling.) It is kept
# because it costs nothing and DOES pay on a wider box or a filtered
# run, where the tail is the whole story. The real remaining lever is
# the slow gates themselves: textcolcmp alone is 291s of the 1659.
KNOWN=qa/sweep-times.txt
PATS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS="$2"; shift 2 ;;
        -o) LOG="$2"; shift 2 ;;
        *) PATS+=("$1"); shift ;;
    esac
done

# Gates that must not share the box with another gate.
#   concurrency/carefulflush/gencomp/gendurable: they time waits, or run
#     several servers of their own
#   gbakverbose: it compares the ENGINE's service line stream against
#     fire-crab's, and a loaded box re-chunks the engine's output
#     mid-line (diagnosed 2026-08-28 - the mangling is the engine's)
#   fetchbatch/textwidth2: each shares its scratch DB NAMES with another
#     gate (batch, temporalwhere)
SERIAL="concurrency carefulflush gbakverbose gencomp gendurable fetchbatch textwidth2 idxcost"

is_serial() { case " $SERIAL " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

gates=()
for f in qa/serve-real-*.sh; do
    n=$(basename "$f" .sh); n=${n#serve-real-}
    if [ ${#PATS[@]} -gt 0 ]; then
        keep=0
        for p in "${PATS[@]}"; do case "$n" in *"$p"*) keep=1 ;; esac; done
        [ $keep -eq 1 ] || continue
    fi
    gates+=("$n")
done

# ...ordered slowest-first from the last run's record
if [ -f "$KNOWN" ] && [ ${#gates[@]} -gt 1 ]; then
    ordered=$(
        for n in "${gates[@]}"; do
            t=$(awk -v g="$n" '$2 == g {print $1}' "$KNOWN" | head -1)
            echo "${t:-99999} $n"
        done | sort -rn | awk '{print $2}'
    )
    gates=()
    while read -r n; do [ -n "$n" ] && gates+=("$n"); done <<<"$ordered"
fi

: > "$LOG"
mkdir -p /tmp/fbhandson && chmod 1777 /tmp/fbhandson 2>/dev/null
TMP=$(mktemp -d /tmp/fc-sweep-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
TIMES="$TMP/times"
: > "$TIMES"

# A private port per gate. Well clear of the engine's 3050 and of every
# gate's own default; the stride leaves room for the gates that start a
# second and third server of their own (PORT+1, PORT+2).
port_of() { echo $((20000 + $1 * 4)); }

run_one() { # <index> <name>
    local i="$1" n="$2" f="qa/serve-real-$2.sh" out="$TMP/$2.out"
    local t0 t1 rc
    t0=$(date +%s)
    # A GATE'S `$1` IS NOT ALWAYS A PORT. Thirteen of them take a
    # <clean-db-path> instead, print a usage line and exit 1 when it is
    # missing - which is what a sweep has always given them, and is not
    # a failure. Handing one a PORT NUMBER makes it try to open a
    # database called "20676" and fail every check it has (measured: 11
    # DIFFs from serve-real-groupby alone). They are told apart by the
    # `PORT="${1:` their own text carries.
    if grep -qF 'PORT="${1:' "$f"; then
        timeout 900 bash "$f" "$(port_of "$i")" >"$out" 2>&1
        rc=$?
    elif fixture=$(fixture_for "$n"); then
        # A GATE WHOSE `$1` IS A DATABASE, not a port. Thirteen of them
        # read a prepared scratch database instead of building one, and
        # for want of it they had never run in ANY sweep - 171 checks
        # over the core query surface (joins, grouping, HAVING,
        # projection, the system catalogue, the type matrix) that
        # nothing was watching. Each gets its OWN COPY, because they
        # write, and its port after it.
        mine="$D_SCRATCH/sweep-$n.fdb"
        cp "$fixture" "$mine" 2>/dev/null && chmod 666 "$mine"
        timeout 900 bash "$f" "$mine" "$(port_of "$i")" >"$out" 2>&1
        rc=$?
        rm -f "$mine"
    else
        timeout 900 bash "$f" >"$out" 2>&1
        rc=$?
    fi
    t1=$(date +%s)
    { echo "=== qa/serve-real-$n.sh"
      cat "$out"
      echo "--- rc=$rc qa/serve-real-$n.sh"
    } >>"$LOG"
    echo "$((t1 - t0)) $n" >>"$TIMES"
    rm -f "$out"
}

D_SCRATCH=/tmp/fbhandson
# WHICH PREPARED DATABASE a `$1`-is-a-database gate wants. Twelve read
# the JOIN scratch (qa/mkjoindb.sh builds it); the type matrix reads its
# own (qa/mktypesdb.sh). A gate not named here is one that takes no
# argument at all.
fixture_for() {
    case "$1" in
        join|outerjoin|project|insert|syscat|joinchain|joingroup|orderagg|groupby|having|query|where)
            echo "$D_SCRATCH/joindb_clean.fdb" ;;
        types) echo "$D_SCRATCH/wiretypes_clean.fdb" ;;
        *) return 1 ;;
    esac
}
# built ONCE, here, so a first run on a fresh box has them
for spec in "joindb_clean.fdb:qa/mkjoindb.sh" "wiretypes_clean.fdb:qa/mktypesdb.sh"; do
    fdb="$D_SCRATCH/${spec%%:*}"
    [ -f "$fdb" ] || bash "${spec##*:}" >/dev/null 2>&1
done

echo "sweep: ${#gates[@]} gates, -j $JOBS, log $LOG"
start=$(date +%s)
i=0
running=0
for n in "${gates[@]}"; do
    i=$((i + 1))
    is_serial "$n" && continue
    run_one "$i" "$n" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || wait
        running=$((running - 1))
    fi
done
wait

# ...and the ones that need the box to themselves
i=10000
for n in "${gates[@]}"; do
    is_serial "$n" || continue
    i=$((i + 1))
    run_one "$i" "$n"
done

end=$(date +%s)
echo "SWEEP DONE" >>"$LOG"
ok=$(grep -c '^OK' "$LOG"); bad=$(grep -cE '^DIFF|^FAIL' "$LOG")
# ...AND A GATE THAT DIED WITHOUT SAYING SO. Counting only DIFF/FAIL
# LINES made a gate that exits non-zero invisible: the thirteen gates
# whose `$1` is a database printed a usage line and exited 1 in every
# sweep, and the summary called it a clean run. An `rc` is a failure
# whether or not the gate got as far as printing one.
died=$(grep -E '^--- rc=[^0]' "$LOG" | grep -cv '^--- rc=0 ')
echo "sweep: $((end - start))s  gates=$(grep -c '^=== ' "$LOG")  OK=$ok  DIFF/FAIL=$bad  rc!=0=$died"
if [ "$bad" -ne 0 ] || [ "$died" -ne 0 ]; then
    grep -E '^DIFF|^FAIL' "$LOG" | head -20
    grep -E '^--- rc=[^0]' "$LOG" | head -20
fi
# keep the record for the next run's ordering (a FULL sweep only: a
# filtered one would drop every gate it did not run)
if [ ${#PATS[@]} -eq 0 ]; then
    sort -rn "$TIMES" > "$KNOWN"
fi
echo "slowest gates:"; sort -rn "$TIMES" | head -8 | awk '{printf "  %4ss  %s\n", $1, $2}'
exit $([ "$bad" -eq 0 ] && echo 0 || echo 1)
