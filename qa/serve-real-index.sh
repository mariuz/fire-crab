#!/bin/bash
# W1: INDEX-DRIVEN RETRIEVAL - the first slice that wires a converted
# subsystem into the running server, so it is gated twice.
#
#   1. THE ANSWERS DO NOT MOVE. Every statement runs against fire-crab
#      and the real engine over twin databases and the rows are
#      compared, exactly as every other gate here does. An index that
#      changes an answer is a bug, not an optimisation.
#
#   2. THE INDEX IS ACTUALLY USED. That is a claim no behaviour gate can
#      make: "wired in but never called" passes all of them. The server
#      logs the access path it chose, and this gate asserts the choice -
#      an index for the shapes that have one, a natural scan for the
#      shapes that do not. Both directions matter: a server that always
#      says "index" is as wrong as one that never does.
#
# What retrieval by index means here, and why it is safe: the index
# names CANDIDATE record numbers, the records are fetched, and THE SAME
# PREDICATE that would have run over a full scan still decides every
# row. Index entries outlive the rows they describe - an UPDATE adds the
# new key and leaves the old, a DELETE removes nothing - so a stale
# entry costs a wasted fetch and cannot produce a wrong row. The DML
# section below is the proof: delete, update a key, re-insert a deleted
# key, and look each one up again.
#
# The MECHANICS are deliberately narrow: single-segment integer indexes
# at scale 0, against an integer literal. A key this server cannot build
# byte-exactly is not a refusal - it is a MISSED ROW, the one failure
# the predicate above cannot catch - so BIGINT, SMALLINT, NUMERIC and
# text columns are checked to scan naturally rather than guess.
#
#   qa/serve-real-index.sh [port]
#
# Needs the real engine on 3050 (FC_REAL_PORT overrides) and node with
# node-firebird.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4554}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-idx-crab.fdb"
B="$D/fc-idx-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (ID INTEGER NOT NULL PRIMARY KEY, DEPT_ID INTEGER,
                  SALARY INTEGER, NAME VARCHAR(6));
CREATE TABLE PLAIN (ID INTEGER, V INTEGER);
CREATE TABLE WIDE (K BIGINT, S SMALLINT, N NUMERIC(9,2), T VARCHAR(6));
COMMIT;
CREATE INDEX EMP_DEPT ON EMP (DEPT_ID);
CREATE INDEX WIDE_K ON WIDE (K);
CREATE INDEX WIDE_S ON WIDE (S);
CREATE INDEX WIDE_N ON WIDE (N);
CREATE INDEX WIDE_T ON WIDE (T);
CREATE INDEX EMP_PAIR ON EMP (DEPT_ID, SALARY);
CREATE DESCENDING INDEX WIDE_SD ON WIDE (S);
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 'c');
INSERT INTO EMP VALUES (4, 3,  50, 'd');
INSERT INTO EMP VALUES (5, NULL, 400, 'e');
INSERT INTO EMP VALUES (6, 1, 200, 'f');
INSERT INTO PLAIN VALUES (1, 10);
INSERT INTO PLAIN VALUES (2, 20);
INSERT INTO WIDE VALUES (9000000000, 7, 12.50, 'aa');
INSERT INTO WIDE VALUES (-9000000000, -7, -3.25, 'bb');
INSERT INTO WIDE VALUES (0, 0, 0.00, NULL);
INSERT INTO WIDE VALUES (9000000000, 7, 12.50, 'cc');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-index.log 2>&1 &
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

query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
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

both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refused: $1" ;;
        *) echo "DIFF $1 answered: [$r]"; fail=1 ;;
    esac
}


# --- the coverage helpers ---------------------------------------------
# The access path is read from the server's own log, which is what makes
# "the subsystem is on the path" an assertion rather than a hope.
LOG=/tmp/fc-serve-index.log
scans_since() { grep -c "$1" "$LOG" 2>/dev/null || true; }

indexed() { # <label> <sql> - answers like the engine AND drives an index
    before=$(scans_since "index scan:")
    both "$1" "$2"
    after=$(scans_since "index scan:")
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and it drove an INDEX"
    else
        echo "DIFF $1 did NOT drive an index (the optimizer chose a scan)"
        fail=1
    fi
}
natural() { # <label> <sql> - answers like the engine AND does NOT
    before=$(scans_since "index scan:")
    both "$1" "$2"
    after=$(scans_since "index scan:")
    ran=$((ran + 1))
    if [ "$after" -eq "$before" ]; then
        echo "OK   ... and it scanned, as it must"
    else
        echo "DIFF $1 drove an index it has no business driving"
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

# --- 1. an equality on a PRIMARY KEY -----------------------------------
indexed "a primary key lookup" "SELECT ID, NAME FROM EMP WHERE ID = 3"
indexed "a key that is not there" "SELECT ID FROM EMP WHERE ID = 99"
indexed "the lowest key" "SELECT NAME FROM EMP WHERE ID = 1"
indexed "the highest key" "SELECT NAME FROM EMP WHERE ID = 6"
indexed "a lookup with a SECOND predicate the index cannot serve" \
        "SELECT ID FROM EMP WHERE ID = 2 AND SALARY > 100"
indexed "... and the same one where the second predicate REJECTS the row" \
        "SELECT ID FROM EMP WHERE ID = 2 AND SALARY > 500"
indexed "a lookup with an ORDER BY above it" \
        "SELECT ID, NAME FROM EMP WHERE ID = 4 ORDER BY NAME"

# --- 2. a NON-unique index: duplicates, and the empty case -------------
indexed "a non-unique index with several matches" \
        "SELECT ID FROM EMP WHERE DEPT_ID = 1 ORDER BY ID"
# An AGGREGATE has its own walk over the records, which this slice does
# not route through the chosen leaf - so the answer is checked and the
# access path is not claimed. Naming it here is the point: the roadmap
# counts 30 retrieval sites and this slice wires the projection's.
both "... counted (the aggregate walk is not index-driven yet)" \
     "SELECT COUNT(*) AS K FROM EMP WHERE DEPT_ID = 1"
indexed "a single match" "SELECT ID FROM EMP WHERE DEPT_ID = 3"
indexed "no match" "SELECT ID FROM EMP WHERE DEPT_ID = 77"
indexed "a negative key" "SELECT ID FROM EMP WHERE DEPT_ID = -1"
indexed "zero as a key" "SELECT ID FROM EMP WHERE DEPT_ID = 0"

# --- 3. what must still SCAN -------------------------------------------
# each of these is a shape the mechanics cannot key, and every one of
# them would be a MISSED ROW rather than a refusal if it guessed
natural "a column with no index" "SELECT ID FROM EMP WHERE SALARY = 300"
natural "a table with no index at all" "SELECT ID FROM PLAIN WHERE ID = 1"
natural "IS NULL, which is not an equality" \
        "SELECT ID FROM EMP WHERE DEPT_ID IS NULL"
natural "no predicate at all" "SELECT ID FROM EMP ORDER BY ID"
natural "an OR of two equalities" \
        "SELECT ID FROM EMP WHERE ID = 1 OR ID = 2 ORDER BY ID"
natural "a NOT EQUAL" "SELECT ID FROM EMP WHERE ID <> 3 ORDER BY ID"
natural "an equality on the SECOND segment of a compound index" \
        "SELECT ID FROM EMP WHERE SALARY = 200 ORDER BY ID"
# the types whose key encoding this slice does not build
# BIGINT and SMALLINT are keyed too - the encoding is the WRITE path's
# own (int64 key for one, the double-form numeric key for the other),
# gated byte-exact against `compress` long before this slice
indexed "a BIGINT key" "SELECT T FROM WIDE WHERE K = 9000000000 ORDER BY T"
indexed "a NEGATIVE BIGINT key" "SELECT T FROM WIDE WHERE K = -9000000000"
indexed "a SMALLINT key" "SELECT T FROM WIDE WHERE S = 7 ORDER BY T"
indexed "a NEGATIVE SMALLINT key" "SELECT T FROM WIDE WHERE S = -7"
natural "a SCALED numeric key" "SELECT T FROM WIDE WHERE N = 12.50 ORDER BY T"
natural "a TEXT key" "SELECT K FROM WIDE WHERE T = 'aa'"


# --- 3b. RANGES ---------------------------------------------------------
# The key encoding is ORDER-PRESERVING - that is what `compress` is for -
# so a byte range IS a value range, and one descent plus a forward walk
# serves `>`, `>=`, `<`, `<=` and BETWEEN. Both bounds are optional and
# each carries its own inclusivity, which is the part that is easy to get
# off by one row.
indexed "a strict lower bound" "SELECT ID FROM EMP WHERE ID > 3 ORDER BY ID"
indexed "an inclusive lower bound" "SELECT ID FROM EMP WHERE ID >= 3 ORDER BY ID"
indexed "a strict upper bound" "SELECT ID FROM EMP WHERE ID < 3 ORDER BY ID"
indexed "an inclusive upper bound" "SELECT ID FROM EMP WHERE ID <= 3 ORDER BY ID"
indexed "both bounds" "SELECT ID FROM EMP WHERE ID > 2 AND ID < 5 ORDER BY ID"
indexed "BETWEEN, which is the inclusive pair" \
        "SELECT ID FROM EMP WHERE ID BETWEEN 2 AND 5 ORDER BY ID"
indexed "a range past every key" "SELECT ID FROM EMP WHERE ID > 100 ORDER BY ID"
indexed "a range before every key" "SELECT ID FROM EMP WHERE ID < -100 ORDER BY ID"
indexed "an EMPTY range - the bounds cross" \
        "SELECT ID FROM EMP WHERE ID > 3 AND ID < 3 ORDER BY ID"
indexed "the whole table, through the index" \
        "SELECT ID FROM EMP WHERE ID > 0 ORDER BY ID"
# a conjunction can only NARROW, so several bounds on one column combine
indexed "two lower bounds - the tighter wins" \
        "SELECT ID FROM EMP WHERE ID >= 2 AND ID >= 4 ORDER BY ID"
indexed "an equality and a range together" \
        "SELECT ID FROM EMP WHERE ID = 4 AND ID > 1 ORDER BY ID"
indexed "a range on a NON-UNIQUE index, with duplicates inside it" \
        "SELECT ID FROM EMP WHERE DEPT_ID >= 1 AND DEPT_ID <= 2 ORDER BY ID"
# NULLs are stored as a zero-length key, which sorts BEFORE every value:
# an upper-bounded range therefore sweeps them up as candidates, and the
# predicate above throws them out - a wasted fetch, never a wrong row
indexed "an upper-bounded range over a column that has NULLs" \
        "SELECT ID FROM EMP WHERE DEPT_ID < 3 ORDER BY ID"
# a DESCENDING index complements its keys, so the tree's byte order is
# the reverse of the value order and the bounds swap
indexed "a range through a DESCENDING index" \
        "SELECT T FROM WIDE WHERE S > -7 ORDER BY T"
indexed "... and the other way" "SELECT T FROM WIDE WHERE S < 7 ORDER BY T"
indexed "... and between" "SELECT T FROM WIDE WHERE S BETWEEN -7 AND 7 ORDER BY T"

# --- 4. the answers themselves, index and scan side by side ------------
# the same question asked two ways: if the index path lost a row, these
# disagree with each other as well as with the engine
both "every row, by scan" "SELECT ID FROM EMP ORDER BY ID"
both "the same row set, one lookup at a time" \
     "SELECT ID FROM EMP WHERE ID = 1 UNION ALL SELECT ID FROM EMP WHERE ID = 2
      UNION ALL SELECT ID FROM EMP WHERE ID = 3 ORDER BY 1"
both "a join whose sides are both looked up" \
     "SELECT E.NAME FROM EMP E JOIN EMP F ON E.ID = F.ID WHERE E.ID = 2"

# --- 5. STALE ENTRIES: the reason an index names candidates -------------
# An entry outlives its record. Each step below leaves one behind, and
# the lookup after it must still answer what the engine answers.
both "insert a row" "INSERT INTO EMP VALUES (7, 4, 700, 'g')"
indexed "... and find it by key" "SELECT ID, NAME FROM EMP WHERE ID = 7"
indexed "... and by the non-unique index" "SELECT ID FROM EMP WHERE DEPT_ID = 4"
both "update the KEY itself" "UPDATE EMP SET ID = 8 WHERE ID = 7"
indexed "... the old key is gone" "SELECT ID FROM EMP WHERE ID = 7"
indexed "... and the new one answers" "SELECT ID, NAME FROM EMP WHERE ID = 8"
both "update a non-unique key" "UPDATE EMP SET DEPT_ID = 9 WHERE ID = 1"
indexed "... the old value no longer matches" \
        "SELECT ID FROM EMP WHERE DEPT_ID = 1 ORDER BY ID"
indexed "... and the new one does" "SELECT ID FROM EMP WHERE DEPT_ID = 9"
both "delete by key" "DELETE FROM EMP WHERE ID = 8"
indexed "... and it is gone" "SELECT ID FROM EMP WHERE ID = 8"
both "the table's own count" "SELECT COUNT(*) AS K FROM EMP"
both "delete several rows" "DELETE FROM EMP WHERE DEPT_ID = 2"
indexed "... none of them answer" "SELECT ID FROM EMP WHERE DEPT_ID = 2"
# THE ONE THIS FOUND: a deleted row's index entry stays, and reading
# uniqueness from the ENTRIES alone refused an insert the engine takes
both "re-insert a DELETED key" "INSERT INTO EMP VALUES (3, 2, 999, 'z')"
indexed "... and it is the new row, not the old one" \
        "SELECT ID, SALARY FROM EMP WHERE ID = 3"
# A genuine duplicate must still be REFUSED. Both servers raise; the
# MESSAGES differ (fire-crab has no unique-violation text of its own
# yet - a pre-existing gap, unchanged by this slice), so this asserts
# the refusal on both sides rather than pretending the wording matches.
ran=$((ran + 1))
a=$(query "INSERT INTO EMP VALUES (3, 2, 111, 'y')" "$PORT" "$A")
b=$(query "INSERT INTO EMP VALUES (3, 2, 111, 'y')" "$REAL" "$B")
case "$a$b" in
    ERR*ERR*) echo "OK   a genuine duplicate is still refused, by both" ;;
    *) echo "DIFF a duplicate was accepted: fc=[$a] engine=[$b]"; fail=1 ;;
esac
both "the whole table, after all of it" "SELECT ID, SALARY FROM EMP ORDER BY ID"

# --- 6. THE COVERAGE CHECK'S OWN TEETH ---------------------------------
# Everything above asserts "an index was used". That claim is only worth
# something if the assertion can FAIL - so a second server runs with the
# index path switched off, and the same lookups are asked again. They
# must answer identically (an index narrows what is read, not what is
# answered) and they must NOT report an index scan.
P2=$((PORT + 1))
LOG2=/tmp/fc-serve-index-noidx.log
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
same_both_ways() { # <label> <sql>
    ran=$((ran + 1))
    idx=$(query "$2" "$PORT" "$A")
    scan=$(query "$2" "$P2" "$A")
    eng=$(query "$2" "$REAL" "$B")
    if [ "$idx" = "$scan" ] && [ "$idx" = "$eng" ]; then
        echo "OK   index and scan agree, and so does the engine: $1"
    else
        echo "DIFF $1"
        echo "     index: $idx"
        echo "     scan:  $scan"
        echo "     engine:$eng"
        fail=1
    fi
}
same_both_ways "a primary key lookup" "SELECT ID, NAME FROM EMP WHERE ID = 4"
same_both_ways "a non-unique lookup" "SELECT ID FROM EMP WHERE DEPT_ID = 9 ORDER BY ID"
same_both_ways "a key with no row" "SELECT ID FROM EMP WHERE ID = 4242"
same_both_ways "a lookup a second predicate narrows" \
               "SELECT ID FROM EMP WHERE ID = 6 AND SALARY = 200"
same_both_ways "the whole table" "SELECT ID, SALARY FROM EMP ORDER BY ID"
same_both_ways "a range" "SELECT ID FROM EMP WHERE ID > 2 AND ID <= 5 ORDER BY ID"
same_both_ways "a range with NULLs below it" \
               "SELECT ID FROM EMP WHERE DEPT_ID < 3 ORDER BY ID"
same_both_ways "an empty range" "SELECT ID FROM EMP WHERE ID > 9 AND ID < 2"
# and the switch really did switch it off
ran=$((ran + 1))
if [ "$(grep -c 'index scan:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   the scan-only server drove NO index (so the checks above can fail)"
else
    echo "DIFF FC_NO_INDEX did not disable the index path - the coverage checks prove nothing"
    fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 90 ]; then
    echo "DIFF only $ran checks ran (expected at least 90) - did one silently skip?"
    fail=1
fi
exit $fail
