#!/bin/bash
# INDEX-DRIVEN SUBQUERY RETRIEVAL - the inner table of a subquery is
# walked through the optimizer's index whenever the subquery's OWN
# residual WHERE names an indexed column, exactly as the engine's inner
# stream does (probed with SET PLANONLY: an inner `K = 5` drives BIG_K
# in every WHERE-side shape, while the plain correlated EXISTS is a hash
# semi-join over one NATURAL inner scan - so the fold model stays).
#
# THE DIFFERENTIAL: the same isql runs the same statement against the
# engine and against fire-crab and the answers must be identical - the
# index narrows what is READ, never what is ANSWERED.
#
# THE COVERAGE: the access path is read from the server's own log
# ("subq index: rel=" / "subq natural: rel="), which is what makes "the
# subquery drove an index" an assertion rather than a hope - and a
# second server with FC_NO_INDEX=1 re-answers everything identically
# while tracing NO "subq index:" line at all, so the assertions above
# are ones that can fail.
#
#   qa/serve-real-subqindex.sh [port]     (the twin runs on port+1)
#
# Builds two identical scratch databases; both are chmod 666 so either
# server's user can open them.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4566}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-subqidx-crab.fdb"
B="$D/fc-subqidx-engine.fdb"
LOG="/tmp/fc-serve-subqidx-$PORT.log"

mkdir -p "$D"
fail=0
ran=0

# T: the outer table, 10 rows. BIG: 10000 rows, 20 duplicates per key so
# the duplicate runs span leaf pages at 8192; K and V indexed, W not.
# U: a UNIQUE key for singleton scalars (keys 10..100 so a moved key can
# land between neighbours).
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(6));
CREATE TABLE BIG (K INTEGER, V INTEGER, W INTEGER);
CREATE TABLE U (K INTEGER UNIQUE, V INTEGER);
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 10) DO BEGIN I = I + 1; INSERT INTO T VALUES (:I, 'n' || :I); END
  I = 0;
  WHILE (I < 10000) DO BEGIN I = I + 1; INSERT INTO BIG VALUES (MOD(:I, 500), :I, :I); END
  I = 0;
  WHILE (I < 10) DO BEGIN I = I + 1; INSERT INTO U VALUES (:I * 10, :I); END
END^
SET TERM ; ^
COMMIT;
CREATE INDEX BIG_K ON BIG (K);
CREATE INDEX BIG_V ON BIG (V);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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

runq() { # <sql> <connect>
    printf 'SET HEADING OFF;\n%s;\n' "$1" |
        "$ISQL" -q -user "$U" -pas "$P" "$2" 2>&1 | tr -s ' \n' ' '
}

same() { # <label> <sql> - the same statement both ways, answers equal
    ran=$((ran + 1))
    fc=$(runq "$2" "127.0.0.1/$PORT:$A")
    en=$(runq "$2" "$B")
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- the coverage helpers ----------------------------------------------
# The access path is read from the server's own log.
count_line() { grep -c "$1" "$LOG" 2>/dev/null || true; }

subq_indexed() { # <label> <sql> - answers alike AND the INNER walk drove an index
    before=$(count_line "subq index: rel=")
    same "$1" "$2"
    after=$(count_line "subq index: rel=")
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and the subquery drove an INDEX"
    else
        echo "DIFF $1: the subquery did NOT drive an index"
        fail=1
    fi
}
subq_natural() { # <label> <sql> - answers alike AND the inner walk scanned
    bi=$(count_line "subq index: rel=")
    bn=$(count_line "subq natural: rel=")
    same "$1" "$2"
    ai=$(count_line "subq index: rel=")
    an=$(count_line "subq natural: rel=")
    ran=$((ran + 1))
    if [ "$ai" -eq "$bi" ] && [ "$an" -gt "$bn" ]; then
        echo "OK   ... and the subquery scanned, as the engine does"
    else
        echo "DIFF $1: expected a natural inner scan (index $bi->$ai, natural $bn->$an)"
        fail=1
    fi
}

# --- 0. the control: the log is being read at all ----------------------
# If this printed nothing the two helpers above would agree with
# everything, so it is checked before anything depends on it.
ran=$((ran + 1))
if [ -s "$LOG" ] && grep -q "listening" "$LOG"; then
    echo "OK   the server log is readable (the coverage checks can see it)"
else
    echo "DIFF the server log is empty - every coverage check below is blind"
    fail=1
fi

# --- 1. IN / NOT IN at the band edges ----------------------------------
# BIG holds K = MOD(i, 500): keys 0..499, 20 rows each. The outer IDs
# 1..10 straddle every band below, so a one-off bound is a DIFFERENT row
# set, not a slower identical one.
subq_indexed "IN with an indexed inner equality" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K = 5)"
subq_indexed "IN with an indexed inner BETWEEN" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K BETWEEN 3 AND 5)"
subq_indexed "IN over an EMPTY band (K = 500 is past the top key)" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K = 500)"
subq_indexed "NOT IN with an indexed inner equality" \
    "SELECT ID FROM T WHERE ID NOT IN (SELECT K FROM BIG WHERE K = 5)"
subq_indexed "the TOP key" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K = 499)"
subq_indexed "the BOTTOM key" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K = 0)"

# --- 2. scalar subqueries ----------------------------------------------
# U's UNIQUE key makes the inner genuinely singleton - a 20-row inner
# would be a runtime engine error, not a fixture.
subq_indexed "scalar through a UNIQUE key" \
    "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K = 70)"
subq_indexed "scalar aggregate over an indexed range" \
    "SELECT ID FROM T WHERE ID > (SELECT MAX(K) FROM BIG WHERE K < 4) ORDER BY ID"

# --- 3. EXISTS ----------------------------------------------------------
subq_indexed "uncorrelated EXISTS with an indexed inner WHERE" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG WHERE K = 5)"
subq_indexed "uncorrelated NOT EXISTS over an empty band" \
    "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM BIG WHERE K = 500)"
# The correlation column cannot narrow the fold - only the RESIDUAL
# can, and V is indexed.
subq_indexed "correlated EXISTS with an indexed residual" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID AND X.V = 5)"
subq_indexed "correlated NOT EXISTS with an indexed residual" \
    "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID AND X.V = 3)"
# ... and with NO residual the engine itself hash-joins over one NATURAL
# inner scan (probed with PLANONLY) - a server that indexed the fold's
# key column would be claiming a retrieval the engine does not make.
subq_natural "correlated EXISTS with no residual scans, as the engine does" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID)"

# --- 4. a correlated subquery in the SELECT list ------------------------
subq_natural "select-list correlated COUNT with no residual" \
    "SELECT ID, (SELECT COUNT(*) FROM BIG X WHERE X.K = T.ID) FROM T ORDER BY ID"
subq_indexed "select-list correlated COUNT with an indexed residual" \
    "SELECT ID, (SELECT COUNT(*) FROM BIG X WHERE X.K = T.ID AND X.V = 5) FROM T ORDER BY ID"

# --- 5. the shapes that must SCAN ---------------------------------------
subq_natural "an inner WHERE on the unindexed column" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE W BETWEEN 1 AND 5)"
subq_natural "an inner query with no WHERE at all" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG)"

# --- 6. a key UPDATE, then the subquery again ---------------------------
# An index entry outlives the version that wrote it, so the moved key is
# named by BOTH its old and its new entry. On this path a stale+current
# double-return does not duplicate a row - it makes the scalar inner
# TWO rows and the whole statement would REFUSE where the engine
# answers. The record-number dedup is what keeps these answering.
same "move the unique key through both servers" \
    "UPDATE U SET K = 75 WHERE K = 70"
subq_indexed "a band covering the OLD and the NEW key answers once" \
    "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K BETWEEN 65 AND 79)"
subq_indexed "the OLD key finds nothing (the stale entry is filtered)" \
    "SELECT ID FROM T WHERE ID IN (SELECT V FROM U WHERE K = 70)"

# --- 7. THE COVERAGE CHECK'S OWN TEETH ---------------------------------
# Everything above asserts "the subquery drove an index". That claim is
# only worth something if the assertion can FAIL - so a second server
# runs with the index path switched off, and the same statements are
# asked again three ways. They must answer identically, and the twin's
# log must hold NO "subq index:" line at all.
P2=$((PORT + 1))
LOG2="/tmp/fc-serve-subqidx-noidx-$PORT.log"
FC_NO_INDEX=1 FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$P2" "$U" "$P" >"$LOG2" 2>&1 &
srv2=$!
trap 'kill $srv $srv2 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$P2" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv2 2>/dev/null || {
    echo "FAIL the scan-only server is not running - port $P2 already in use?"
    exit 1
}
same3() { # <label> <sql> - indexed server, scan-only server, engine: all equal
    ran=$((ran + 1))
    idx=$(runq "$2" "127.0.0.1/$PORT:$A")
    scan=$(runq "$2" "127.0.0.1/$P2:$A")
    eng=$(runq "$2" "$B")
    if [ "$idx" = "$scan" ] && [ "$idx" = "$eng" ]; then
        echo "OK   index and scan agree, and so does the engine: $1"
    else
        echo "DIFF $1"
        echo "     index: [$idx]"
        echo "     scan:  [$scan]"
        echo "     engine:[$eng]"
        fail=1
    fi
}
same3 "IN with an indexed inner equality" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K = 5)"
same3 "IN with an indexed inner BETWEEN" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K BETWEEN 3 AND 5)"
same3 "IN over an empty band" \
    "SELECT ID FROM T WHERE ID IN (SELECT K FROM BIG WHERE K = 500)"
same3 "NOT IN with an indexed inner equality" \
    "SELECT ID FROM T WHERE ID NOT IN (SELECT K FROM BIG WHERE K = 5)"
same3 "scalar through a UNIQUE key (the moved one)" \
    "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K = 75)"
same3 "scalar aggregate over an indexed range" \
    "SELECT ID FROM T WHERE ID > (SELECT MAX(K) FROM BIG WHERE K < 4) ORDER BY ID"
same3 "uncorrelated EXISTS with an indexed inner WHERE" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG WHERE K = 5)"
same3 "correlated EXISTS with an indexed residual" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID AND X.V = 5)"
same3 "correlated NOT EXISTS with an indexed residual" \
    "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID AND X.V = 3)"
same3 "correlated EXISTS with no residual" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID)"
same3 "select-list correlated COUNT with an indexed residual" \
    "SELECT ID, (SELECT COUNT(*) FROM BIG X WHERE X.K = T.ID AND X.V = 5) FROM T ORDER BY ID"
same3 "a band covering the old and the new key" \
    "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K BETWEEN 65 AND 79)"
# the switch really did switch it off - and the twin still traced its
# scans, so the zero below is "no index", not "no trace"
ran=$((ran + 1))
if [ "$(grep -c 'subq index:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   the scan-only server drove NO subquery index (so the checks above can fail)"
else
    echo "DIFF FC_NO_INDEX did not disable the subquery index path - the coverage checks prove nothing"
    fail=1
fi
ran=$((ran + 1))
if [ "$(grep -c 'subq natural:' "$LOG2" 2>/dev/null || true)" -gt 0 ]; then
    echo "OK   ... and it still traced its natural inner scans"
else
    echo "DIFF the scan-only server traced nothing - its zero above is blindness, not proof"
    fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 54 ]; then
    echo "DIFF only $ran checks ran (expected at least 54) - did one silently skip?"
    fail=1
fi
exit $fail
