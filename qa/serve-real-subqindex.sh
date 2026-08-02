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
# Section 8 asserts the OUTER side of the same statements: after the
# fold the outer retrieval indexes through a RECONSTRUCTED gatekeeper
# text ("index scan:"/"natural scan:"), DML target walks through their
# own pair ("dml index:"/"dml natural:"), and parameters beside a fold
# defer their band to EXECUTE (node drives those; the engine answers
# through its inet listener on FC_REAL_PORT, default 3050).
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
# The OUTER retrieval's strings are the ordinary projection pair -
# "index scan:"/"natural scan:" - because after the fold the outer IS
# an ordinary retrieval through the same Plan machinery. Safe against
# cross-gate bleed: every gate's log is its own per-port file, and the
# only other gates that grep these strings run no subquery statements.
# Note "subq index: rel=" does NOT contain "index scan: rel=" - the
# four counters below never see each other's lines.
outer_indexed() { # <label> <sql> - answers alike AND the OUTER walk drove an index
    before=$(count_line "index scan: rel=")
    same "$1" "$2"
    after=$(count_line "index scan: rel=")
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and the OUTER retrieval drove an INDEX"
    else
        echo "DIFF $1: the outer retrieval did NOT drive an index"
        fail=1
    fi
}
outer_natural() { # <label> <sql> - answers alike AND the outer scanned
    bi=$(count_line "index scan: rel=")
    bn=$(count_line "natural scan: rel=")
    same "$1" "$2"
    ai=$(count_line "index scan: rel=")
    an=$(count_line "natural scan: rel=")
    ran=$((ran + 1))
    if [ "$ai" -eq "$bi" ] && [ "$an" -gt "$bn" ]; then
        echo "OK   ... and the outer scanned, matching the engine's plan"
    else
        echo "DIFF $1: expected a natural outer scan (index $bi->$ai, natural $bn->$an)"
        fail=1
    fi
}
# The DML walk's pair is DISTINCT - "dml index:"/"dml natural:" - so
# serve-real-index's zero-"index scan:" claim over its FC_NO_INDEX twin
# (a log full of plain DML) and this gate's DML coverage stay
# independently greppable.
dml_indexed() { # <label> <sql> - alike AND the DML target walk drove an index
    before=$(count_line "dml index: rel=")
    same "$1" "$2"
    after=$(count_line "dml index: rel=")
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and the DML walk drove an INDEX"
    else
        echo "DIFF $1: the DML walk did NOT drive an index"
        fail=1
    fi
}
dml_natural() { # <label> <sql> - alike AND the DML target walk scanned
    bi=$(count_line "dml index: rel=")
    bn=$(count_line "dml natural: rel=")
    same "$1" "$2"
    ai=$(count_line "dml index: rel=")
    an=$(count_line "dml natural: rel=")
    ran=$((ran + 1))
    if [ "$ai" -eq "$bi" ] && [ "$an" -gt "$bn" ]; then
        echo "OK   ... and the DML walk scanned, as it must"
    else
        echo "DIFF $1: expected a natural DML walk (index $bi->$ai, natural $bn->$an)"
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

# --- 8. THE OUTER QUERY'S OWN INDEX OVER FOLDED SUBQUERIES --------------
# The fold rewrites the WHERE's TOKENS, but every choose_index call used
# to receive the ORIGINAL text, whose `(SELECT` the optimizer gatekeeper
# refuses - so the outer always scanned where the engine indexes
# (probed: `ID = (SELECT MAX(K) FROM U)` is T INDEX (RDB$PRIMARY1)).
# Now the folded stream is rendered back into a reconstructed statement
# and the outer retrieval chooses like any other.
#
# First the fixture speaks its spec'd keys again: section 6 moved U's
# key 70 to 75. The move BACK is itself the first DML ever to drive an
# index here (fcopt refuses a raw UPDATE - "not a SELECT" - so both DML
# choose_index calls were dead weight until the reconstruction), and
# its band K = 75 already covers a current-and-stale entry pair of the
# same record, putting the record-number dedup on the path at once.
dml_indexed "the key moves back (the FIRST DML ever to drive an index)" \
    "UPDATE U SET K = 70 WHERE K = 75"

# 8a. WHERE-side scalar folds: mid-band, both band EDGES, and a band
# past the top key (zero rows both ways - an empty band, not an error)
outer_indexed "outer = scalar fold, mid-band" \
    "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K = 70)"
outer_indexed "outer = scalar fold at the BOTTOM key" \
    "SELECT ID FROM T WHERE ID = (SELECT MIN(V) FROM U)"
outer_indexed "outer = scalar fold at the TOP key" \
    "SELECT ID FROM T WHERE ID = (SELECT MAX(V) FROM U)"
outer_indexed "outer = scalar fold PAST the top key (empty band)" \
    "SELECT ID FROM T WHERE ID = (SELECT MAX(K) FROM U)"
# navigation comes off the reconstructed text too (engine: T ORDER
# RDB$PRIMARY1 for a folded range under ORDER BY)
outer_indexed "outer range fold under ORDER BY (navigation)" \
    "SELECT ID FROM T WHERE ID > (SELECT MAX(V) FROM U WHERE K < 40) ORDER BY ID"
outer_indexed "an OR of two folds (two bands of one index)" \
    "SELECT ID FROM T WHERE ID = (SELECT MIN(V) FROM U) OR ID = (SELECT MAX(V) FROM U)"

# 8b. the shapes the ENGINE does not index: IN/NOT IN fold to an
# IN-list whose parens fcopt refuses, and the engine HASHES these
# (probed: PLAN HASH (T NATURAL, U NATURAL) / T NATURAL) - so the scan
# is the CORRECT plan, and this pins it against anyone teaching fcopt
# IN-lists later, which would index where the engine hashes.
outer_natural "IN (subquery) stays a hash-shaped scan" \
    "SELECT ID FROM T WHERE ID IN (SELECT V FROM U)"
outer_natural "NOT IN (subquery) stays a scan" \
    "SELECT ID FROM T WHERE ID NOT IN (SELECT V FROM U)"

# 8c. folded EXISTS. An uncorrelated EXISTS folds to a DECIDED conjunct,
# rendered as its truth's no-op comparison - beside an indexable
# conjunct the index survives (engine: T INDEX (RDB$PRIMARY1)). In an
# OR the decided branch is non-matchable and the band builder refuses -
# a scan, which is also the engine's own choice for the OR. The
# CORRELATED EXISTS rewrite is an IN-list - paren-bound, so the outer
# scans where the engine indexes: rows equal, the scan is the fold's
# price until fcopt learns IN-lists (divergence PINNED, not hidden).
outer_indexed "folded EXISTS beside an indexable conjunct" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U WHERE K = 70) AND ID = 5"
outer_natural "folded EXISTS in an OR scans" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U WHERE K = 70) OR ID = 5"
outer_natural "correlated EXISTS beside an equality scans (engine indexes; rows equal - the fold's price)" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM BIG X WHERE X.K = T.ID AND X.V = 5) AND ID = 5"

# 8d. select-list folds. The uncorrelated fold re-plans through the
# rewritten text and already indexed its outer when the WHERE was clean
# (regression-pinned here); a WHERE-side fold beside it lands on the
# reconstruction; the CORRELATED select-list outer used to hard-code
# index: None. The no-WHERE ordered correlated select must NOT navigate:
# the engine answers it PLAN SORT (T NATURAL) - probed.
outer_indexed "uncorrelated select-list fold + literal WHERE (the pinned win)" \
    "SELECT ID, (SELECT COUNT(*) FROM U) FROM T WHERE ID = 5"
outer_indexed "select-list fold + WHERE-side fold together" \
    "SELECT ID, (SELECT COUNT(*) FROM U) FROM T WHERE ID = (SELECT MAX(V) FROM U)"
outer_indexed "correlated select-list + literal WHERE" \
    "SELECT ID, (SELECT COUNT(*) FROM BIG X WHERE X.K = T.ID AND X.V = 5) FROM T WHERE ID = 5"
outer_natural "correlated select-list, ORDER BY, no WHERE (engine: SORT NATURAL)" \
    "SELECT ID, (SELECT COUNT(*) FROM BIG X WHERE X.K = T.ID) FROM T ORDER BY ID"

# 8e. parameters beside a fold - isql cannot bind, so node drives both
# servers (the engine through its inet listener). The deferred text is
# the RECONSTRUCTION: at execute the re-plan must not see `(SELECT`.
REAL="${FC_REAL_PORT:-3050}"
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
    pfold() { # <label> <sql> <json-args> <coverage: index|deferred|rows-only>
        ran=$((ran + 1))
        bidx=$(count_line "index scan: rel=")
        bdef=$(count_line "(deferred)")
        a=$(pquery "$2" "$PORT" "$A" "$3")
        b=$(pquery "$2" "$REAL" "$B" "$3")
        if [ "$a" = "$b" ]; then
            echo "OK   $1: $a"
        else
            echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1
        fi
        aidx=$(count_line "index scan: rel=")
        adef=$(count_line "(deferred)")
        case "$4" in
        index)
            ran=$((ran + 1))
            if [ "$aidx" -gt "$bidx" ]; then
                echo "OK   ... and an index line appeared (prepare-time band beside the ?)"
            else
                echo "DIFF $1: no outer index line"; fail=1
            fi ;;
        deferred)
            ran=$((ran + 1))
            if [ "$adef" -gt "$bdef" ]; then
                echo "OK   ... and its band was built at EXECUTE over the reconstruction"
            else
                echo "DIFF $1: no (deferred) line - the reconstructed text did not reach resolve_access"
                fail=1
            fi ;;
        esac
    }
    # the fold names the band, the ? narrows further: the band exists at
    # PREPARE and the bound conjunct is re-checked per candidate
    pfold "a fold beside a ? (band at prepare, candidates re-checked)" \
        "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K = 70) AND NAME = ?" '["n7"]' index
    # only the ? could bound: no band at prepare, DeferredAccess carries
    # the reconstructed text, the band arrives at EXECUTE
    pfold "a ? beside a decided fold (band at EXECUTE)" \
        "SELECT ID FROM T WHERE ID = ? AND 5 = (SELECT V FROM U WHERE K = 50)" "[7]" deferred
    pfold "... and NULL bound matches nothing, like the engine" \
        "SELECT ID FROM T WHERE ID = ? AND 5 = (SELECT V FROM U WHERE K = 50)" "[null]" rows-only
else
    echo "DIFF node not found - the parameter checks cannot run"
    fail=1
fi

# 8f. DML through the reconstruction - the walk that was never reachable
# before. The moved-key cases exercise dml_targets_at's stale-entry law:
# an index entry outlives the version that wrote it, so a band can name
# one record through its OLD and its NEW key - the record-number dedup
# writes it ONCE, and the CURRENT image (not the entry key) decides the
# filter, or a moved row is silently skipped (measured: verifying the
# entry against the image dropped row 12 from `ID BETWEEN 6 AND 13`
# where the engine writes it).
dml_indexed "UPDATE through a scalar fold" \
    "UPDATE T SET NAME = 'z' WHERE ID = (SELECT V FROM U WHERE K = 70)"
same "... and the row it wrote" "SELECT ID, NAME FROM T ORDER BY ID"
dml_indexed "DELETE through an empty band deletes nothing" \
    "DELETE FROM T WHERE ID = (SELECT MAX(K) FROM U)"
dml_natural "an unindexed DML WHERE scans" \
    "UPDATE T SET NAME = 'n1' WHERE NAME = 'n1'"
# move U's key: the subquery's walk then sees stale+current entries
dml_indexed "the key moves forward again" \
    "UPDATE U SET K = 75 WHERE K = 70"
dml_indexed "UPDATE through a band over the moved key (subq dedups, DML indexes)" \
    "UPDATE T SET NAME = 'y' WHERE ID = (SELECT V FROM U WHERE K BETWEEN 65 AND 79)"
# move T's OWN key: the DML target index now holds a stale entry at 7
# and a current one at 12 for the SAME record
dml_indexed "a plain DML equality drives the index too" \
    "UPDATE T SET ID = 12 WHERE ID = 7"
dml_indexed "a band covering the OLD and NEW key writes the moved row ONCE" \
    "UPDATE T SET NAME = 'q' WHERE ID BETWEEN 6 AND 13"
dml_indexed "DELETE aimed at the STALE key deletes nothing (the image decides)" \
    "DELETE FROM T WHERE ID = 7"
same "the whole table after the DML section" \
    "SELECT ID, NAME FROM T ORDER BY ID"

# 8g. the twin re-answers the outer-index statements (state has moved
# on: T's 7 is now 12, U's key is at 75)
same3 "outer scalar fold at the bottom key" \
    "SELECT ID FROM T WHERE ID = (SELECT MIN(V) FROM U)"
same3 "outer scalar fold through the moved key (empty: its T row moved too)" \
    "SELECT ID FROM T WHERE ID = (SELECT V FROM U WHERE K = 75)"
same3 "outer range fold under ORDER BY" \
    "SELECT ID FROM T WHERE ID > (SELECT MAX(V) FROM U WHERE K < 40) ORDER BY ID"
same3 "an OR of two folds" \
    "SELECT ID FROM T WHERE ID = (SELECT MIN(V) FROM U) OR ID = (SELECT MAX(V) FROM U)"
same3 "IN (subquery) over the moved state" \
    "SELECT ID FROM T WHERE ID IN (SELECT V FROM U)"
same3 "folded EXISTS beside an indexable conjunct" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U WHERE K = 75) AND ID = 5"
same3 "uncorrelated select-list fold + literal WHERE" \
    "SELECT ID, (SELECT COUNT(*) FROM U) FROM T WHERE ID = 5"
same3 "correlated select-list + literal WHERE" \
    "SELECT ID, (SELECT COUNT(*) FROM BIG X WHERE X.K = T.ID AND X.V = 5) FROM T WHERE ID = 5"
# a DML all three ways: fc applies it twice to A (idempotent by
# construction), the engine once to B - the STATE check right after is
# what the equality means
same3 "a DML through the twin (idempotent, so the double apply is safe)" \
    "UPDATE T SET NAME = 'w' WHERE ID = (SELECT MIN(V) FROM U)"
same3 "the whole table, all three ways" \
    "SELECT ID, NAME FROM T ORDER BY ID"

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
# the OUTER and DML claims get the same teeth: the twin answered the
# section-8 statements identically while driving NO outer index and NO
# DML index anywhere in its whole log - while still tracing its scans,
# so each zero is "no index", not "no trace"
ran=$((ran + 1))
if [ "$(grep -c 'index scan:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   the scan-only server drove NO outer index either"
else
    echo "DIFF FC_NO_INDEX did not disable the outer index path"
    fail=1
fi
ran=$((ran + 1))
if [ "$(grep -c 'dml index:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   ... and NO DML index"
else
    echo "DIFF FC_NO_INDEX did not disable the DML index path"
    fail=1
fi
ran=$((ran + 1))
if [ "$(grep -c 'natural scan:' "$LOG2" 2>/dev/null || true)" -gt 0 ]; then
    echo "OK   ... while still tracing its natural outer scans"
else
    echo "DIFF the scan-only server traced no outer scans - the zeros above are blindness"
    fail=1
fi
ran=$((ran + 1))
if [ "$(grep -c 'dml natural:' "$LOG2" 2>/dev/null || true)" -gt 0 ]; then
    echo "OK   ... and its natural DML walks"
else
    echo "DIFF the scan-only server traced no DML walks - the DML zero above is blindness"
    fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 122 ]; then
    echo "DIFF only $ran checks ran (expected at least 122) - did one silently skip?"
    fail=1
fi
exit $fail
