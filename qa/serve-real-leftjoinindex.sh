#!/bin/bash
# INDEX-DRIVEN LEFT-JOIN INNER SIDE - the inner side of a LEFT JOIN is
# probed once per outer row through the optimizer's index instead of
# being materialised whole, exactly as the engine's own plan does.
#
# WHY ONLY LEFT. Re-probed with SET PLANONLY on this very fixture:
#
#   CHI LEFT JOIN PAR ON PAR.K = CHI.K
#     PLAN JOIN (CHI NATURAL, PAR INDEX (RDB$PRIMARY1))
#   CHI LEFT JOIN DUP ON DUP.K = CHI.K
#     PLAN JOIN (CHI NATURAL, DUP INDEX (DUP_K))
#   CHI LEFT JOIN NOIX ON NOIX.K = CHI.K
#     PLAN JOIN (CHI NATURAL, NOIX NATURAL)
#   CHI LEFT JOIN PAR ... LEFT JOIN DUP ON DUP.K = PAR.K
#     PLAN JOIN (JOIN (CHI NATURAL, PAR INDEX (RDB$PRIMARY1)), DUP INDEX (DUP_K))
#   CHI JOIN PAR ON PAR.K = CHI.K            PLAN HASH (CHI NATURAL, PAR NATURAL)
#   CHI, PAR WHERE PAR.K = CHI.K             PLAN HASH (CHI NATURAL, PAR NATURAL)
#   PAR A JOIN PAR B ON B.K = A.K            PLAN HASH ("A" NATURAL, "B" NATURAL)
#
# A LEFT join NEVER hashes: the engine's plan IS this executor's tree -
# driver = the syntactic left, inner = the syntactic right, index on the
# inner's ON column when one exists and NATURAL when none does - and
# that structural agreement is the whole licence for the probe. An
# INNER, comma or self join HASHes, so those stay a materialised scan
# and are PINNED here: a server that always says "index" is as wrong as
# one that never does.
#
# THE DIFFERENTIAL: the same isql runs the same statement against the
# engine and against fire-crab and the answers must be identical, ROW
# ORDER INCLUDED - an index narrows what is READ, and with it WHICH ON
# EVALUATIONS HAPPEN, never what is ANSWERED.
#
# That wording is exact, and the ordinary "never what is ANSWERED" is
# NOT, which a refute pass established rather than argued: an ON that
# RAISES is value-gated by the band, so the probe evaluates it over the
# rows the index reaches and the scan evaluates it over all of them.
# `ONEN LEFT JOIN RZ ON RZ.K = O.K AND RZ.T > 0` (O.K NULL, RZ.T
# unconvertible) answers the padded row here and raises 22018 under
# FC_NO_INDEX=1. THE PROBE IS THE ENGINE'S ANSWER - the engine indexes
# that inner side too - so the fix was to state the invariant correctly,
# not to make the paths agree. Section 7's twin is therefore an
# equivalence oracle for NON-RAISING ONs, which is every check it runs.
#
# THE COVERAGE: the access path is read from the server's own log
# ("join index: rel=" / "join natural: side="), which is what makes "the
# inner side drove an index" an assertion rather than a hope - and a
# second server with FC_NO_INDEX=1 re-answers everything identically
# while tracing NO "join index:" line at all.
#
# WHAT IS DELIBERATELY NOT HERE: an ON carrying a VALUE-GATED RAISER on
# the inner side (`ON PAR.K = CHI.K AND PAR.N > 0`). The engine raises
# there per the rows its INDEX reaches, so the probe path is the engine's
# behaviour and the FC_NO_INDEX scan path is not - the two paths
# legitimately disagree, and section 7's byte-equality would be asserting
# the wrong thing. Pinned separately, not here.
#
# AND THE SIZE OF THE REMAINING GAP, measured by that same refute pass
# and stated here because section 5 would otherwise read as a clean
# bill: SEVEN inner sides the ENGINE indexes and this probe declined -
# a DESCENDING index, ~~a NUMERIC(9,2) index~~, ~~NUMERIC(38,0)~~, ~~a VIEW
# inner (the engine flattens it)~~, ~~a DERIVED inner~~, ~~an expression in
# the ON (`RZ.K = O.K + 0`)~~, ~~an OR in the ON~~, and ~~the engine's bitmap
# AND of two indexes~~. Their ROWS agree, which is what section 5 asserts
# and all it asserts; with a RAISING ON they do not, because fire-crab
# scans where the engine keys.
#
# NONE now - Slice B is closed. In order: the scaled NUMERIC inner side
# (the literal reaches the column's scale); an EXPRESSION on the outer
# side of the ON (`CHI.K + 0` evaluated per driving row to the value the
# band probes with); an OR in the ON (one band per DNF branch, their
# UNION deduplicated on acceptance by `records_for_2pc`, every branch
# required servable); a VIEW or DERIVED inner that is a PLAIN PROJECTION
# of one base table (the engine FLATTENS it, so the probe keys that base
# table through an output-column-to-base-field map, declining any side
# with a WHERE/DISTINCT/aggregate/window); the BITMAP AND of two indexes
# (two ON equalities on two indexed columns - band on one, the ON
# re-checks the other, the single-column band a superset of the
# conjunction); and a NUMERIC(38,0) INT128 inner (IDX_BCD - the same
# encoder the write path uses takes an i64-range value AS i128, so the
# retrieval band's bytes are the engine's; a value too wide for i64
# never becomes a literal, so it scans, never mis-keys).
#
#   qa/serve-real-leftjoinindex.sh [port]     (the twin runs on port+1)
#
# Builds two identical scratch databases; both are chmod 666 so either
# server's user can open them.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4777}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-w1a-crab.fdb"
B="$D/fc-w1a-engine.fdb"
LOG="/tmp/fc-serve-leftjoinidx-$PORT.log"

mkdir -p "$D"
fail=0
ran=0

# CHI is the driver: 300 rows, K = MOD(ID,80)+1 with every 17th row
# NULL - so it holds keys with one partner, keys with SIX partners in
# DUP, ORPHAN keys (61..80, past PAR's top) and NULL keys, each of them
# many times over.
#   PAR   unique inner index (the PK)
#   DUP   non-unique inner index, six rows per key, plus one NULL key
#   NOIX  no index at all - the inner must scan
#   EMPT  indexed but EMPTY - every outer row's band is empty
#   DESCT indexed DESCENDING only - a band this server cannot build
#         byte-exactly (its keys are complemented), so it must scan
#   WIDEK one index per family: BIGINT (keyable), NUMERIC(9,2) (scaled,
#         keyable since the literal is carried to the column's scale)
#         and VARCHAR (a text key against a numeric outer value)
#   VPAR  a view over PAR - the engine FLATTENS it into the join and
#         fire-crab keys its base table through the flatten
#   BAND  TWO single-column indexes (K1, K2) - a two-equality ON is the
#         engine's bitmap AND; this server bands on one and re-checks the
#         other through the ON
#   BIG   a NUMERIC(38,0) (INT128 / IDX_BCD) index, plus one real 38-digit
#         key - an i64-range join value keys its own IDX_BCD band and
#         navigates past the 39-digit one; and a WIDE integer LITERAL
#         (>i64) in a WHERE keys and scan-compares in i128 (section 8),
#         which fire-crab used to refuse at the tokenizer
#   WIDEDRV an INT128 DRIVER whose key is >i64: the probe's band carries
#         the wide OUTER value (not just a literal) into the IDX_BCD band
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE PAR (K INTEGER NOT NULL PRIMARY KEY, N VARCHAR(8));
CREATE TABLE DUP (K INTEGER, N VARCHAR(8));
CREATE TABLE NOIX (K INTEGER, N VARCHAR(8));
CREATE TABLE EMPT (K INTEGER, N VARCHAR(8));
CREATE TABLE DESCT (K INTEGER, N VARCHAR(8));
CREATE TABLE CHI (ID INTEGER, K INTEGER, N VARCHAR(8));
CREATE TABLE WIDEK (K BIGINT, NM NUMERIC(9,2), T VARCHAR(8));
CREATE TABLE BAND (K1 INTEGER, K2 INTEGER, N VARCHAR(8));
CREATE TABLE BIG (K NUMERIC(38,0), N VARCHAR(8));
CREATE TABLE WIDEDRV (ID INTEGER, K NUMERIC(38,0));
COMMIT;
CREATE INDEX DUP_K ON DUP (K);
CREATE INDEX EMPT_K ON EMPT (K);
CREATE DESCENDING INDEX DESCT_K ON DESCT (K);
CREATE INDEX WIDEK_K ON WIDEK (K);
CREATE INDEX WIDEK_NM ON WIDEK (NM);
CREATE INDEX WIDEK_T ON WIDEK (T);
CREATE INDEX BAND_K1 ON BAND (K1);
CREATE INDEX BAND_K2 ON BAND (K2);
CREATE INDEX BIG_K ON BIG (K);
CREATE VIEW VPAR AS SELECT K, N FROM PAR;
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 60) DO BEGIN I = I + 1; INSERT INTO PAR VALUES (:I, 'p' || :I); END
  I = 0;
  WHILE (I < 120) DO BEGIN I = I + 1; INSERT INTO DUP VALUES (MOD(:I, 20) + 1, 'd' || :I); END
  I = 0;
  WHILE (I < 40) DO BEGIN I = I + 1; INSERT INTO NOIX VALUES (:I, 'x' || :I); END
  I = 0;
  WHILE (I < 3) DO BEGIN I = I + 1; INSERT INTO DESCT VALUES (:I, 'z' || :I); END
  I = 0;
  WHILE (I < 300) DO BEGIN I = I + 1;
    INSERT INTO CHI VALUES (:I, CASE WHEN MOD(:I,17) = 0 THEN NULL ELSE MOD(:I, 80) + 1 END, 'c' || :I); END
  I = 0;
  WHILE (I < 30) DO BEGIN I = I + 1; INSERT INTO WIDEK VALUES (:I, :I, 't' || :I); END
  I = 0;
  WHILE (I < 100) DO BEGIN I = I + 1;
    INSERT INTO BAND VALUES (MOD(:I, 10) + 1, MOD(:I, 5) + 1, 'b' || :I); END
  I = 0;
  WHILE (I < 60) DO BEGIN I = I + 1; INSERT INTO BIG VALUES (:I, 'g' || :I); END
END^
SET TERM ; ^
COMMIT;
INSERT INTO DUP VALUES (NULL, 'dnull');
-- a real 38-digit key in the tree: the small join keys must navigate
-- PAST it, which only holds if the IDX_BCD key order is the engine's
INSERT INTO BIG VALUES (99999999999999999999999999999999999999, 'ghuge');
-- an INT128 DRIVER: a small key, a WIDE key that matches BIG's 38-digit
-- one (the value the probe's band must carry past i64), a wide key with
-- no partner, and a NULL
INSERT INTO WIDEDRV VALUES (1, 5);
INSERT INTO WIDEDRV VALUES (2, 99999999999999999999999999999999999999);
INSERT INTO WIDEDRV VALUES (3, 40000000000000000000);
INSERT INTO WIDEDRV VALUES (4, NULL);
COMMIT;
SET STATISTICS INDEX DUP_K;
SET STATISTICS INDEX EMPT_K;
SET STATISTICS INDEX WIDEK_K;
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
# The readiness probe answers "SOMETHING is listening", not "OUR server
# is listening". If the port was already taken, fcwire exited at bind
# and every check below would run against the OTHER server - a gate that
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
        echo "DIFF $1"
        echo "     engine: [$(printf '%.300s' "$en")]"
        echo "     fc:     [$(printf '%.300s' "$fc")]"
        fail=1
    fi
}

# --- the coverage helpers ----------------------------------------------
# The access path is read from the server's own log. "join index:" is a
# DISTINCT string from "index scan:" and "dml index:" on purpose: those
# gates assert ZERO of their own line over logs full of other traffic,
# and each pair stays independently greppable. (Note "join index: rel="
# does not contain "index scan: rel=", so the counters never see each
# other's lines.)
count_line() { grep -c "$1" "$LOG" 2>/dev/null || true; }

join_indexed() { # <label> <sql> <expected new index lines>
    before=$(count_line "join index: rel=")
    same "$1" "$2"
    after=$(count_line "join index: rel=")
    ran=$((ran + 1))
    if [ $((after - before)) -eq "$3" ]; then
        echo "OK   ... and $3 join step(s) drove an INDEX"
    else
        echo "DIFF $1: expected $3 indexed join step(s), saw $((after - before))"
        fail=1
    fi
}
join_natural() { # <label> <sql> - answers alike AND every step scanned
    bi=$(count_line "join index: rel=")
    bn=$(count_line "join natural: side=")
    same "$1" "$2"
    ai=$(count_line "join index: rel=")
    an=$(count_line "join natural: side=")
    ran=$((ran + 1))
    if [ "$ai" -eq "$bi" ] && [ "$an" -gt "$bn" ]; then
        echo "OK   ... and the inner side scanned, as the engine's plan does"
    else
        echo "DIFF $1: expected a natural inner side (index $bi->$ai, natural $bn->$an)"
        fail=1
    fi
}
join_hashed() { # <label> <sql> - answers alike AND the inner side was HASHED
    # An equi-join whose inner key is an INTEGER column with NO index: rather
    # than scan the whole inner per driver, this server groups it once by the
    # key and looks up the bucket (the engine's own HASH plan). A distinct
    # "join hash:" trace line, so it counts apart from an index probe and a
    # whole-inner scan. Two spellings: `rel=` when the hashed side is a
    # base relation, `side=` when it is a materialised derived side (which
    # has no relation of its own to name) - both are the hash path.
    bh=$(count_line "join hash: ")
    same "$1" "$2"
    ah=$(count_line "join hash: ")
    ran=$((ran + 1))
    if [ "$ah" -gt "$bh" ]; then
        echo "OK   ... and the inner side was HASHED (keyed in one pass, no index)"
    else
        echo "DIFF $1: expected a hashed inner side (hash $bh->$ah)"
        fail=1
    fi
}
# the DRIVER's own index - a WHERE constraining the outer side drives it
# by that index ("driver index:", distinct from the inner probe's line)
driver_indexed() { # <label> <sql> - alike AND the DRIVER drove an index
    before=$(count_line "driver index: rel=")
    same "$1" "$2"
    after=$(count_line "driver index: rel=")
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and the DRIVER drove its own index"
    else
        echo "DIFF $1: the driver did NOT drive an index"
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

# --- 1. the indexed LEFT join answers what the engine answers ----------
# Row sets compared EXACTLY, order included. The unordered ones are the
# O1 claim: records_for sorts its candidates by RECORD NUMBER when it is
# not navigating, which is the same storage order a full scan yields, so
# the joined sequence does not move. FIRST 5 turns that from "an
# unordered result either way" into a different SET OF ROWS.
join_indexed "unique inner index, ordered" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K ORDER BY CHI.ID" 1
join_indexed "unique inner index, UNORDERED (the row sequence must not move)" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K" 1
join_indexed "non-unique inner index: SIX partners per key" \
    "SELECT CHI.ID, DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K" 1
join_indexed "... and FIRST 5 of it (order-as-a-SET-of-rows)" \
    "SELECT FIRST 5 CHI.ID, DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K" 1
join_indexed "COUNT over the non-unique inner" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K" 1
join_indexed "the ON written the other way round (outer column first)" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN PAR ON CHI.K = PAR.K" 1
join_indexed "the inner is an ALIAS (the probe must re-spell the BARE table)" \
    "SELECT CHI.ID, X.N FROM CHI LEFT JOIN PAR X ON X.K = CHI.K ORDER BY CHI.ID" 1
join_indexed "a BIGINT inner key against an INTEGER outer one" \
    "SELECT CHI.ID, W.T FROM CHI LEFT JOIN WIDEK W ON W.K = CHI.K ORDER BY CHI.ID" 1

# --- 2. the ON's extra conjuncts, and a WHERE on each side -------------
# The band is built from the EQUALITY alone; the whole ON still runs
# over every candidate, and the WHERE still runs above the join.
join_indexed "an extra ON conjunct (band on the equality only)" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K AND PAR.N = 'p7' ORDER BY CHI.ID" 1
join_indexed "an extra ON conjunct naming the OUTER side" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K AND CHI.ID < 40 ORDER BY CHI.ID" 1
join_indexed "a WHERE on the OUTER side" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.ID = 7" 1
# A GROUP BY over the join folds ABOVE the join tree, which the probe is
# part of: the inner side is still probed per driving row (a JoinGroup
# routes through the SAME base+parts+join_rows a plain join does), so the
# grouped join is not handicapped - it inherits the plain join's probe.
# The driver scans in both, as it must (a driver index is a separate,
# pinned concern).
join_indexed "a GROUP BY over the join still probes the inner" \
    "SELECT CHI.K, COUNT(PAR.N) AS C FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K GROUP BY CHI.K ORDER BY CHI.K" 1
join_indexed "... and a global aggregate over the join probes too" \
    "SELECT COUNT(PAR.N) AS C FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K" 1
# THE DRIVER's own index: a WHERE constraining the OUTER side drives it by
# that index, as the engine does (PLAN JOIN (PAR INDEX(...), DUP ...)).
# The inner still probes; the Filter above the join re-checks the whole
# WHERE. Row order is the driver's index order, which is the engine's.
driver_indexed "a WHERE keys the unique DRIVER (equality on its PK)" \
    "SELECT PAR.N, DUP.N FROM PAR LEFT JOIN DUP ON DUP.K = PAR.K WHERE PAR.K = 5 ORDER BY DUP.N"
driver_indexed "a WHERE keys the NON-UNIQUE driver (6 equal-key rows)" \
    "SELECT COUNT(*) AS C FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K = 5"
driver_indexed "... and its rows UNORDERED (the driver's index order IS the engine's)" \
    "SELECT DUP.N, PAR.N FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K = 5"
driver_indexed "the driver keys UNDER A GROUP BY too (base = the indexed side)" \
    "SELECT DUP.K, COUNT(PAR.N) AS C FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K = 5 GROUP BY DUP.K"
# a RANGE on the driver keys too - the row order is safe because an index
# retrieval yields RECNO order (a record bitmap) on BOTH sides, the same
# order a scan gives, so the UNORDERED differential holds. The band is a
# real range, only the sentinel that blesses the index is an equality.
driver_indexed "a RANGE on the driver (COUNT)" \
    "SELECT COUNT(*) AS C FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K > 15"
driver_indexed "... and its rows UNORDERED (recno order, both sides)" \
    "SELECT DUP.N FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K > 18"
driver_indexed "a BETWEEN on the driver (two range bounds)" \
    "SELECT DUP.N, PAR.N FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K BETWEEN 17 AND 19 ORDER BY DUP.N"
# A WHERE on the INNER side demotes the LEFT to an INNER and the engine
# then FLIPS the driver (PLAN JOIN (PAR NATURAL, CHI INDEX ...)). This
# executor cannot flip - its tree is fixed by the SQL - so it keeps
# probing the inner. The rows are the engine's either way; only the plan
# shape diverges, and it diverges at HEAD too, with or without a probe.
join_indexed "a WHERE on the INNER side (engine flips the driver; rows equal)" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE PAR.N = 'p7' ORDER BY CHI.ID" 1

# --- 3. NULLs, orphans, duplicates, an empty inner ---------------------
# A NULL outer key names NO band and never joins - and the padded row
# must still be emitted, with the ON evaluated over it. A NULL INNER key
# is never a partner: a point-equality band cannot reach the NULL
# entries Firebird also indexes, and NULL equals nothing.
join_indexed "outer rows with a NULL key are padded, not dropped" \
    "SELECT CHI.ID, PAR.K FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K IS NULL ORDER BY CHI.ID" 1
join_indexed "... and there are exactly that many of them" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K IS NULL" 1
join_indexed "the ANTI-JOIN: orphans and NULL keys, and nothing else" \
    "SELECT CHI.ID FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE PAR.K IS NULL ORDER BY CHI.ID" 1
join_indexed "a NULL INNER key is never a partner" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K WHERE DUP.K IS NULL" 1
join_indexed "one outer key, all six of its partners, in storage order" \
    "SELECT DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K WHERE CHI.ID = 4" 1
join_indexed "an EMPTY indexed inner pads every outer row" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN EMPT ON EMPT.K = CHI.K" 1
join_indexed "... and every one of them is padded" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN EMPT ON EMPT.K = CHI.K WHERE EMPT.K IS NULL" 1

# --- 4. the chain: each step probes its own inner ----------------------
# The engine plans the LEFT chain left-deep with BOTH inners indexed -
# fire-crab's fold exactly. The second step's outer value lives in the
# accumulated row at the offset the first step just added, and when the
# first step padded it that value is NULL - which names no band, which
# is the answer.
join_indexed "a chain of two LEFT JOINs, both inners probed" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K LEFT JOIN DUP ON DUP.K = PAR.K" 2
join_indexed "... and its rows, ordered" \
    "SELECT CHI.ID, PAR.N, DUP.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K LEFT JOIN DUP ON DUP.K = PAR.K WHERE CHI.ID < 30 ORDER BY CHI.ID, DUP.N" 2

# --- 5. the shapes that HASH or fall back to a scan --------------------
# Each one is asserted to answer identically too: a hash or a scan costs
# work, never a row.
# An UNINDEXED INTEGER inner key is HASHED now (grouped once, not scanned
# per driver) - the engine's HASH plan, O(N + M) not O(N x M).
join_hashed "no index on the inner INTEGER column: hashed" \
    "SELECT CHI.ID, NOIX.N FROM CHI LEFT JOIN NOIX ON NOIX.K = CHI.K ORDER BY CHI.ID"
# ...nor this one. A DESCENDING inner index was the first of the seven;
# its keys are complemented, which the band arithmetic now follows.
join_indexed "a DESCENDING-only inner index" \
    "SELECT CHI.ID, DESCT.N FROM CHI LEFT JOIN DESCT ON DESCT.K = CHI.K ORDER BY CHI.ID" 1
# ...and this one is no longer among them. A scaled NUMERIC inner index
# was one of the SEVEN shapes the refute pass measured as "the engine
# indexes it and this probe declines"; the literal now reaches the
# column's own scale, so the band builds and the probe takes it. The
# outer value here is an INTEGER meeting a NUMERIC(9,2) inner - exactly
# the carry that was missing.
join_indexed "a scaled NUMERIC inner index" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN WIDEK W ON W.NM = CHI.K" 1
join_indexed "... and its rows, ordered" \
    "SELECT CHI.ID, W.T FROM CHI LEFT JOIN WIDEK W ON W.NM = CHI.K ORDER BY CHI.ID" 1
# a TEXT equi-join (both VARCHAR): the inner's index cannot be driven (a
# collation makes its key a collation key, which choose_index declines), so
# it HASHES instead - by the trailing-trimmed string, the engine's own HASH
# for a text join.
join_hashed "a TEXT equi-join hashes (no drivable text index)" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN WIDEK W ON W.T = CHI.N"
join_natural "a NON-EQUALITY ON (a range band does not exclude the NULL entries)" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN PAR ON PAR.K > CHI.K"
# ...and this one closes another of them. An EXPRESSION on the OUTER
# side of the ON equality (`CHI.K + 0`) is evaluated per driving row to
# the value the band probes with, while the INNER side stays a bare
# indexable column - which is the shape the engine indexes too.
join_indexed "an EXPRESSION on the outer side of the ON" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K + 0" 1
join_indexed "... and its rows, ordered" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K + 0 ORDER BY CHI.ID" 1
# ...and this one closes another. An OR in the ON is a UNION OF BANDS,
# one per branch - `PAR.K = CHI.K` (per driving row) and `PAR.K = 5`
# (a constant band) - deduplicated on acceptance, which is what saves it
# from the MISSING set of rows a single band would leave. Every branch
# must be servable or the whole probe falls back to a scan.
join_indexed "an OR in the ON, one branch constant" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K OR PAR.K = 5" 1
join_indexed "... and its rows: each driver pairs with its key AND row 5" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K OR PAR.K = 5 ORDER BY CHI.ID, PAR.K" 1
# ...and the last two of section 5 close. A VIEW or a DERIVED table that
# is a PLAIN projection of one base relation is FLATTENED to that table -
# its rows ARE the table's - so the ON keys the base index through an
# output-column-to-base-field map. VPAR is `SELECT K, N FROM PAR`; the
# derived side is the same by another name.
join_indexed "a VIEW inner side, flattened to its base table" \
    "SELECT CHI.ID, VPAR.N FROM CHI LEFT JOIN VPAR ON VPAR.K = CHI.K ORDER BY CHI.ID" 1
join_indexed "a DERIVED inner side, flattened the same" \
    "SELECT CHI.ID, DD.N FROM CHI LEFT JOIN (SELECT K, N FROM PAR) DD ON DD.K = CHI.K ORDER BY CHI.ID" 1
# but a FILTER is a transform the flatten would DROP - a derived side
# with its own WHERE keeps its materialised plan. It is not therefore
# scanned per driving row: the two decisions are separate, so a side
# that cannot be read as base records is still materialised ONCE and
# HASHED on its own output column. (Until 2026-09-02 it fell all the way
# to a per-driver scan, which is quadratic; the rows agreed either way,
# because the inner plan applies the filter the probe cannot.)
join_hashed "a DERIVED inner with a WHERE does NOT flatten" \
    "SELECT CHI.ID, DW.N FROM CHI LEFT JOIN (SELECT K, N FROM PAR WHERE K > 30) DW ON DW.K = CHI.K ORDER BY CHI.ID"
# ...and the last of section 5. TWO indexed ON columns (`BAND.K1 = CHI.K
# AND BAND.K2 = CHI.K`) is the engine's BITMAP AND of two indexes. This
# server names candidates from ONE of them (a single-column band) and
# lets the ON re-check the other - the single band is a SUPERSET of the
# conjunction's matches, so the rows are the engine's, the plan a
# residual-filter where the engine intersects.
join_indexed "two indexed ON columns: one band, the ON re-checks the rest" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN BAND ON BAND.K1 = CHI.K AND BAND.K2 = CHI.K" 1
join_indexed "... and its rows, ordered (the K2 conjunct removes K1-only rows)" \
    "SELECT CHI.ID, BAND.N FROM CHI LEFT JOIN BAND ON BAND.K1 = CHI.K AND BAND.K2 = CHI.K ORDER BY CHI.ID, BAND.N" 1
# ...and the LAST of the seven. A NUMERIC(38,0) inner (INT128, IDX_BCD)
# is keyed now: the driving row's i64-range value builds an IDX_BCD band
# through the SAME encoder the write path uses, so its bytes are the
# engine's and the descent walks past the 38-digit key in the tree.
join_indexed "a NUMERIC(38,0) INT128 inner index" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN BIG ON BIG.K = CHI.K" 1
join_indexed "... and its rows, ordered" \
    "SELECT CHI.ID, BIG.N FROM CHI LEFT JOIN BIG ON BIG.K = CHI.K ORDER BY CHI.ID" 1
# and the OTHER direction: a WIDE OUTER value (not a literal). The driver
# WIDEDRV's key is >i64; the probe's band carries it into the IDX_BCD band
# instead of capping at i64 and scanning. Row 2's key IS BIG's 38-digit
# one, so it must find 'ghuge'; row 3's wide key has no partner (padded).
join_indexed "an INT128 driver: the band carries a WIDE outer value" \
    "SELECT WIDEDRV.ID, BIG.N FROM WIDEDRV LEFT JOIN BIG ON BIG.K = WIDEDRV.K ORDER BY WIDEDRV.ID" 1

# --- 6. INNER equi-joins drive the inner's index too ------------------
# The engine HASHes these (verbatim plans in the header), but this server
# has no hash join - so its choice is a nested loop that either SCANS the
# inner for every driver (O(N x M)) or PROBES its index (O(N log M)). The
# probe is the better plan and the one it takes: an INNER equi-join with an
# ON drives the inner's index exactly as a LEFT one does, since both loop
# the same driver one accumulated row at a time (`join_step` just drops an
# unmatched INNER driver where LEFT pads it). The driver stays the
# SYNTACTIC LEFT - so the row order does not move from what the full scan
# gave, only the inner reads fewer rows. COUNT(*), so the order the engine's
# HASH would give is not being claimed; the count is the whole assertion.
join_indexed "INNER equi-join drives the inner index" \
    "SELECT COUNT(*) FROM CHI JOIN PAR ON PAR.K = CHI.K" 1
join_indexed "self-join on the PK drives the inner index" \
    "SELECT COUNT(*) FROM PAR A JOIN PAR B ON B.K = A.K" 1
# --- and the kinds that still SCAN their inner -------------------------
# A comma join carries its key in the WHERE, not an ON, so no probe is
# built (the key never reaches `build_join_probe`). RIGHT and FULL never
# take an INDEX - their mirror needs the whole other side materialised -
# but since 2026-08-21 that side is HASHED by the ON's key by row, so
# each driver row tries its bucket rather than the side.
join_natural "comma join: key in the WHERE, no ON probe" \
    "SELECT COUNT(*) FROM CHI, PAR WHERE PAR.K = CHI.K"
join_hashed "RIGHT join: the whole other side, hashed by the key" \
    "SELECT COUNT(*) FROM CHI RIGHT JOIN PAR ON PAR.K = CHI.K"
join_hashed "FULL join: two loops, one each direction, the side hashed" \
    "SELECT COUNT(*) FROM CHI FULL JOIN PAR ON PAR.K = CHI.K"

# --- 7. THE MOVED-KEY CASES --------------------------------------------
# "Wired in but never used" passes every behaviour gate, and the FIRST
# ACTIVATION is when the latent bugs fire. An index entry OUTLIVES the
# version that wrote it, so a record whose key changed is named by BOTH
# its old and its new entry - and this walk never navigates, so nothing
# verifies the entry against the image. What keeps it right is that the
# ON re-runs over the FETCHED values (an index NAMES candidates, the
# predicate DECIDES) and that records_for dedups on ACCEPTANCE by record
# number. Each DML below runs through BOTH servers, so both files end in
# the same state, and the join is then re-asked of both.
same "DELETE a matched inner key" "DELETE FROM PAR WHERE K = 5"
join_indexed "the deleted key's outer rows are padded now" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K = 5 ORDER BY CHI.ID" 1
same "MOVE an inner key onto a formerly ORPHAN outer key" "UPDATE PAR SET K = 61 WHERE K = 7"
join_indexed "the moved row appears under its NEW key" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K = 61 ORDER BY CHI.ID" 1
join_indexed "... and NOT under the old one (the ON re-checks the fetched value)" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K = 7 ORDER BY CHI.ID" 1
same "RE-INSERT the deleted key" "INSERT INTO PAR VALUES (5, 'p5b')"
join_indexed "the re-inserted row joins again, once" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K = 5 ORDER BY CHI.ID" 1
same "INSERT a partner for an outer key that was an orphan" "INSERT INTO PAR VALUES (70, 'p70')"
join_indexed "the padded row became a real joined row" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K = 70 ORDER BY CHI.ID" 1
# AWAY AND BACK: a key that leaves a row and comes back can end up with
# two IDENTICAL CURRENT entries in different leaf pages. Both name the
# same record; the joined row must appear ONCE, not twice.
same "move six DUP rows AWAY from key 5" "UPDATE DUP SET K = 999 WHERE K = 5"
same "... and BACK again" "UPDATE DUP SET K = 5 WHERE K = 999"
join_indexed "the away-and-back rows join ONCE each, not twice" \
    "SELECT CHI.ID, DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K WHERE CHI.K = 5 ORDER BY CHI.ID, DUP.N" 1
join_indexed "... and the whole non-unique join still counts the same both ways" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K" 1
join_indexed "the whole unique join after all of it" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K ORDER BY CHI.ID" 1

# --- 8. THE COVERAGE CHECK'S OWN TEETH ---------------------------------
# Everything above asserts "the inner side drove an index". That claim
# is only worth something if it can FAIL - so a second server runs with
# the index path switched off and the same statements are asked again
# three ways. They must answer IDENTICALLY, and the twin's log must hold
# NO "join index:" line at all: an index narrows what is READ, never
# what is ANSWERED.
P2=$((PORT + 1))
LOG2="/tmp/fc-serve-leftjoinidx-noidx-$PORT.log"
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
same3() { # <label> <sql> - probing server, scan-only server, engine: all equal
    ran=$((ran + 1))
    idx=$(runq "$2" "127.0.0.1/$PORT:$A")
    scan=$(runq "$2" "127.0.0.1/$P2:$A")
    eng=$(runq "$2" "$B")
    if [ "$idx" = "$scan" ] && [ "$idx" = "$eng" ]; then
        echo "OK   probe and scan agree, and so does the engine: $1"
    else
        echo "DIFF $1"
        echo "     probe: [$(printf '%.300s' "$idx")]"
        echo "     scan:  [$(printf '%.300s' "$scan")]"
        echo "     engine:[$(printf '%.300s' "$eng")]"
        fail=1
    fi
}
same3 "unique inner index, ordered" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K ORDER BY CHI.ID"
same3 "unique inner index, UNORDERED" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K"
same3 "non-unique inner index, UNORDERED" \
    "SELECT CHI.ID, DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K"
same3 "FIRST 5 of it" \
    "SELECT FIRST 5 CHI.ID, DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K"
same3 "an extra ON conjunct" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K AND PAR.N = 'p7' ORDER BY CHI.ID"
same3 "a WHERE on the outer side" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.ID = 7"
same3 "a WHERE on the inner side" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE PAR.N = 'p7' ORDER BY CHI.ID"
same3 "the anti-join" \
    "SELECT CHI.ID FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE PAR.K IS NULL ORDER BY CHI.ID"
same3 "NULL outer keys" \
    "SELECT CHI.ID, PAR.K FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K IS NULL ORDER BY CHI.ID"
same3 "the away-and-back key" \
    "SELECT CHI.ID, DUP.N FROM CHI LEFT JOIN DUP ON DUP.K = CHI.K WHERE CHI.K = 5 ORDER BY CHI.ID, DUP.N"
same3 "the moved key, under its new value" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K WHERE CHI.K = 61 ORDER BY CHI.ID"
same3 "the empty indexed inner" \
    "SELECT COUNT(*) FROM CHI LEFT JOIN EMPT ON EMPT.K = CHI.K"
same3 "the BIGINT inner key" \
    "SELECT CHI.ID, W.T FROM CHI LEFT JOIN WIDEK W ON W.K = CHI.K ORDER BY CHI.ID"
same3 "the expression on the outer side of the ON" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K + 0 ORDER BY CHI.ID"
same3 "the OR in the ON (a union of bands)" \
    "SELECT CHI.ID, PAR.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K OR PAR.K = 5 ORDER BY CHI.ID, PAR.K"
same3 "the flattened VIEW inner" \
    "SELECT CHI.ID, VPAR.N FROM CHI LEFT JOIN VPAR ON VPAR.K = CHI.K ORDER BY CHI.ID"
same3 "the flattened DERIVED inner" \
    "SELECT CHI.ID, DD.N FROM CHI LEFT JOIN (SELECT K, N FROM PAR) DD ON DD.K = CHI.K ORDER BY CHI.ID"
same3 "two indexed ON columns (one band + ON residual)" \
    "SELECT CHI.ID, BAND.N FROM CHI LEFT JOIN BAND ON BAND.K1 = CHI.K AND BAND.K2 = CHI.K ORDER BY CHI.ID, BAND.N"
same3 "the NUMERIC(38,0) INT128 inner" \
    "SELECT CHI.ID, BIG.N FROM CHI LEFT JOIN BIG ON BIG.K = CHI.K ORDER BY CHI.ID"
same3 "the INT128 driver with a WIDE outer value" \
    "SELECT WIDEDRV.ID, BIG.N FROM WIDEDRV LEFT JOIN BIG ON BIG.K = WIDEDRV.K ORDER BY WIDEDRV.ID"
same3 "a GROUP BY over the join (the fold sits above the probe)" \
    "SELECT CHI.K, COUNT(PAR.N) AS C FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K GROUP BY CHI.K ORDER BY CHI.K"
# a WIDE integer LITERAL (>i64) against the INT128 column - fire-crab
# used to REFUSE it at the tokenizer; now it keys the IDX_BCD band (index
# server) and scan-compares in i128 (FC_NO_INDEX server), both the
# engine's answer. The literal itself is 38 nines, a genuine INT128.
same3 "an INT128 literal equality (the 38-digit key)" \
    "SELECT N FROM BIG WHERE K = 99999999999999999999999999999999999999"
same3 "an INT128 literal range (> a value past i64)" \
    "SELECT COUNT(*) FROM BIG WHERE K > 1000000000000000000000"
same3 "an INT128 literal equality on a small in-range value" \
    "SELECT N FROM BIG WHERE K = 40000000000000000000 OR K = 7 ORDER BY N"
same3 "the chain of two LEFT JOINs" \
    "SELECT CHI.ID, PAR.N, DUP.N FROM CHI LEFT JOIN PAR ON PAR.K = CHI.K LEFT JOIN DUP ON DUP.K = PAR.K WHERE CHI.ID < 30 ORDER BY CHI.ID, DUP.N"
same3 "the unindexed inner" \
    "SELECT CHI.ID, NOIX.N FROM CHI LEFT JOIN NOIX ON NOIX.K = CHI.K ORDER BY CHI.ID"
same3 "the view inner" \
    "SELECT CHI.ID, VPAR.N FROM CHI LEFT JOIN VPAR ON VPAR.K = CHI.K ORDER BY CHI.ID"
same3 "the INNER join pin" \
    "SELECT COUNT(*) FROM CHI JOIN PAR ON PAR.K = CHI.K"
same3 "the FULL join pin" \
    "SELECT COUNT(*) FROM CHI FULL JOIN PAR ON PAR.K = CHI.K"

# the switch really did switch it off - and the twin still traced its
# natural sides, so the zero below is "no index", not "no trace"
ran=$((ran + 1))
if [ "$(grep -c 'join index:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   the scan-only server probed NO join index (so the checks above can fail)"
else
    echo "DIFF FC_NO_INDEX did not disable the join probe - the coverage checks prove nothing"
    fail=1
fi
ran=$((ran + 1))
if [ "$(grep -c 'join natural:\|join hash:' "$LOG2" 2>/dev/null || true)" -gt 0 ]; then
    echo "OK   ... and it still traced its inner sides (natural or hashed, never indexed)"
else
    echo "DIFF the scan-only server traced nothing - its zero above is blindness, not proof"
    fail=1
fi
# and the probing server really did probe: a positive count here is what
# makes every "expected N indexed steps" above a measurement
ran=$((ran + 1))
if [ "$(count_line 'join index: rel=')" -gt 20 ]; then
    echo "OK   the probing server drove the join index throughout"
else
    echo "DIFF the probing server barely probed - the coverage counts are not measuring the probe"
    fail=1
fi

# --- 9. a PARAMETERISED driver WHERE defers its band to EXECUTE --------
# isql cannot bind a `?`, so node drives it. A `WHERE driver.col = ?` has
# no band at prepare; the driver keys at EXECUTE from the bound value, and
# fire-crab's log shows the DEFERRED driver index. Rows must match the
# engine both ways.
if command -v node >/dev/null 2>&1; then
    pquery() { # <sql> <port> <db> <json-args>
        n=0
        while [ $n -lt 6 ]; do
            r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" FC_ARGS="$4" node -e '
              process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
              const F=require("node-firebird");
              F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                        user:"SYSDBA",password:"masterkey",encoding:"NONE"},(e,db)=>{
                if(e){console.log("CONN_ERR");process.exit(0);}
                db.query(process.env.FC_Q,JSON.parse(process.env.FC_ARGS),(e2,r)=>{
                  if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
                  console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
                  db.detach();process.exit(0);});});' 2>/dev/null)
            case "$r" in
                CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
                *) printf '%s' "$r"; return ;;
            esac
        done
        printf 'CONN_ERR'
    }
    pdriver() { # <label> <sql> <json-args>
        ran=$((ran + 1))
        before=$(count_line "driver index: rel=")
        a=$(pquery "$2" "$PORT" "$A" "$3")
        b=$(pquery "$2" "$REAL" "$B" "$3")
        after=$(count_line "driver index: rel=")
        if [ "$a" = "$b" ]; then echo "OK   $1: $a"; else echo "DIFF $1"; echo "  fc: $a"; echo "  en: $b"; fail=1; fi
        ran=$((ran + 1))
        if [ "$after" -gt "$before" ]; then
            echo "OK   ... and the driver's band was built at EXECUTE"
        else
            echo "DIFF $1: no deferred driver index"; fail=1
        fi
    }
    REAL="${FC_REAL_PORT:-3050}"
    pdriver "a parameterised driver equality (unique PK)" \
        "SELECT PAR.N, DUP.N FROM PAR LEFT JOIN DUP ON DUP.K = PAR.K WHERE PAR.K = ? ORDER BY DUP.N" "[5]"
    pdriver "a parameterised driver equality (non-unique, 6 rows)" \
        "SELECT COUNT(*) AS C FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K = ?" "[5]"
    pdriver "a parameterised driver equality UNDER A GROUP BY" \
        "SELECT DUP.K, COUNT(PAR.N) AS C FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K = ? GROUP BY DUP.K" "[5]"
    pdriver "a parameterised driver RANGE (deferred range band)" \
        "SELECT DUP.N FROM DUP LEFT JOIN PAR ON PAR.K = DUP.K WHERE DUP.K > ? ORDER BY DUP.N" "[18]"
fi

rm -f "$A" "$B"
if [ "$ran" -lt 114 ]; then
    echo "DIFF only $ran checks ran (expected at least 114) - did one silently skip?"
    fail=1
fi
exit $fail
