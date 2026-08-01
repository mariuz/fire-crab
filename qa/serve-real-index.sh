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
CREATE TABLE WIDE (K BIGINT, S SMALLINT, N NUMERIC(9,2), T VARCHAR(6), DS INTEGER);
CREATE TABLE NU (K INTEGER, V VARCHAR(4));
CREATE TABLE CP (A INTEGER, B INTEGER, C INTEGER, S VARCHAR(8), KC CHAR(6));
CREATE TABLE PARENT (K INTEGER NOT NULL PRIMARY KEY, V VARCHAR(4));
CREATE TABLE CHILD (ID INTEGER, PK INTEGER REFERENCES PARENT (K));
CREATE TABLE TPARENT (K VARCHAR(4) NOT NULL PRIMARY KEY);
CREATE TABLE TCHILD (ID INTEGER, PK VARCHAR(4) REFERENCES TPARENT (K));
COMMIT;
CREATE INDEX EMP_DEPT ON EMP (DEPT_ID);
CREATE INDEX WIDE_K ON WIDE (K);
CREATE INDEX WIDE_S ON WIDE (S);
CREATE INDEX WIDE_N ON WIDE (N);
CREATE INDEX WIDE_T ON WIDE (T);
CREATE INDEX EMP_PAIR ON EMP (DEPT_ID, SALARY);
CREATE DESCENDING INDEX WIDE_SD ON WIDE (S);
CREATE DESCENDING INDEX WIDE_DS ON WIDE (DS);
CREATE UNIQUE INDEX NU_K ON NU (K);
CREATE INDEX CP2 ON CP (A, B);
CREATE INDEX CP3 ON CP (A, B, C);
CREATE DESCENDING INDEX CPD ON CP (A, B);
CREATE INDEX CP_S ON CP (S);
CREATE INDEX CP_K ON CP (KC);
CREATE TABLE TX (S VARCHAR(8) NOT NULL, N INTEGER);
CREATE UNIQUE INDEX TX_S ON TX (S);
CREATE TABLE BIG (ID INTEGER, A INTEGER, B INTEGER);
CREATE INDEX BIG_AB ON BIG (A, B);
CREATE INDEX BIG_A ON BIG (A);
CREATE TABLE DEL (ID INTEGER, K INTEGER);
CREATE INDEX DEL_K ON DEL (K);
CREATE TABLE TD (ID INTEGER, C VARCHAR(8));
CREATE DESCENDING INDEX TD_CD ON TD (C);
CREATE TABLE GC (ID INTEGER NOT NULL PRIMARY KEY, K INTEGER);
CREATE INDEX GC_K ON GC (K);
CREATE TABLE RT (ID INTEGER NOT NULL PRIMARY KEY, K INTEGER);
CREATE INDEX RT_K ON RT (K);
CREATE TABLE UNJ (ID INTEGER, A INTEGER, D DECIMAL(4,1), F FLOAT, B BIGINT);
CREATE INDEX UNJ_A ON UNJ (A);
CREATE INDEX UNJ_D ON UNJ (D);
CREATE INDEX UNJ_AF ON UNJ (A, F);
CREATE INDEX UNJ_B ON UNJ (B);
CREATE INDEX UNJ_AD ON UNJ (A, D);
CREATE TABLE SN (ID INTEGER, BG BIGINT);
CREATE TABLE Z128 (ID INTEGER, K INTEGER, N NUMERIC(38,6));
CREATE TABLE CTB (ID INTEGER, K INTEGER, N BIGINT);
CREATE INDEX SN_B ON SN (BG);
CREATE INDEX Z128_I ON Z128 (K, N);
CREATE INDEX CTB_I ON CTB (K, N);
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 'c');
INSERT INTO EMP VALUES (4, 3,  50, 'd');
INSERT INTO EMP VALUES (5, NULL, 400, 'e');
INSERT INTO EMP VALUES (6, 1, 200, 'f');
INSERT INTO PLAIN VALUES (1, 10);
INSERT INTO PLAIN VALUES (2, 20);
INSERT INTO WIDE VALUES (9000000000, 7, 12.50, 'aa', 1);
INSERT INTO WIDE VALUES (-9000000000, -7, -3.25, 'bb', 2);
INSERT INTO WIDE VALUES (0, 0, 0.00, NULL, 3);
INSERT INTO WIDE VALUES (9000000000, 7, 12.50, 'cc', 4);
INSERT INTO WIDE VALUES (-9223372036854775808, -1, -1.00, 'mn', 5);
INSERT INTO WIDE VALUES (9223372036854775807, 1, 1.00, 'mx', 6);
INSERT INTO NU VALUES (2, 'two');
INSERT INTO NU VALUES (1, 'one');
INSERT INTO NU VALUES (NULL, 'nil');
INSERT INTO NU VALUES (NULL, 'nil2');
INSERT INTO CP VALUES (1, 10, 100, 'aa', 'aa');
INSERT INTO CP VALUES (1, 20, 200, 'bb', 'bb');
INSERT INTO CP VALUES (1, NULL, 300, NULL, NULL);
INSERT INTO CP VALUES (2, 10, 400, 'cc', 'cc');
INSERT INTO CP VALUES (-1, 5, 500, 'dd  ', 'dd');
INSERT INTO CP VALUES (0, 0, 600, '', '');
INSERT INTO CP VALUES (-2, NULL, 700, 'ee', 'ee');
INSERT INTO TX VALUES ('b', 1);
INSERT INTO TX VALUES ('A', 2);
INSERT INTO TX VALUES ('a', 3);
INSERT INTO TX VALUES ('', 4);
INSERT INTO TX VALUES ('ab', 5);
INSERT INTO TX VALUES ('B', 6);
INSERT INTO DEL VALUES (1, 10);
INSERT INTO DEL VALUES (2, 20);
INSERT INTO DEL VALUES (3, 20);
INSERT INTO DEL VALUES (4, 20);
INSERT INTO TD VALUES (1, 'ab');
INSERT INTO TD VALUES (2, 'abc');
COMMIT;
-- ENGINE-SIDE mutations, done by isql while neither server is running.
-- Both shapes below need the ENGINE's own index maintenance and its
-- garbage collector; fire-crab performing the same writes does not
-- produce them, so no check that goes through the wire can reach these.
--
-- (a) a deleted row whose version is then GARBAGE COLLECTED, which
--     RELEASES its slot. `DataPage::records()` skips released slots, so
--     indexing the nth SURVIVOR is not the record at slot n - after the
--     collection every later entry fetched SOMEONE ELSE'S record.
INSERT INTO GC VALUES (1, 5);
INSERT INTO GC VALUES (2, 20);
INSERT INTO GC VALUES (3, 20);
INSERT INTO GC VALUES (4, 20);
COMMIT;
DELETE FROM GC WHERE ID = 1;
COMMIT;
SELECT COUNT(*) FROM GC;
COMMIT;
-- (b) a key that LEAVES and COMES BACK inside ONE transaction, so the
--     index holds two live entries with the same (key, record) pair.
INSERT INTO RT VALUES (1, 10);
INSERT INTO RT VALUES (2, 11);
INSERT INTO RT VALUES (3, 12);
INSERT INTO UNJ VALUES (1, 1, 0.1, 0, -9223372036854775808);
INSERT INTO UNJ VALUES (2, 2, 0.2, 1, 5);
INSERT INTO UNJ VALUES (3, 3, 0.3, -2.5, 7);
INSERT INTO UNJ VALUES (4, 1, 9.9, 3.5, 9);
INSERT INTO UNJ VALUES (5, 5, 0.3, 0.5, 11);
INSERT INTO UNJ VALUES (6, 6, 0.6, 0.6, 12);
INSERT INTO UNJ VALUES (7, 7, 1.7, 1.7, 13);
INSERT INTO SN VALUES (1, -9223372036854775808);
INSERT INTO SN VALUES (2, -9223372036854775807);
INSERT INTO SN VALUES (3, 0);
INSERT INTO Z128 VALUES (1, 1, 592189395975403986605735411451.897512);
INSERT INTO Z128 VALUES (2, 1, 1.000000);
INSERT INTO Z128 VALUES (3, 1, 613081327444869060060576626715.019256);
INSERT INTO Z128 VALUES (4, 1, 0.250000);
INSERT INTO CTB VALUES (1, 1, -9223372036854775808);
INSERT INTO CTB VALUES (4, 1, 1);
INSERT INTO CTB VALUES (7, 1, -2147483648);
COMMIT;
UPDATE RT SET K = 25 WHERE ID = 1;
UPDATE RT SET K = 10 WHERE ID = 1;
COMMIT;
-- A DUPLICATE RUN LONG ENOUGH TO SPAN LEAF PAGES. Every fixture in this
-- gate is otherwise a handful of rows, and a handful of rows is ONE leaf
-- page - so the descent's page-boundary behaviour was untestable here by
-- construction. It took 6000 identical keys to reach it.
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 6000) DO BEGIN I = I + 1; INSERT INTO BIG VALUES (:I, 1, NULL); END
  I = 0;
  WHILE (I < 40) DO BEGIN I = I + 1; INSERT INTO BIG VALUES (10000 + :I, 2, :I); END
END^
SET TERM ; ^
INSERT INTO PARENT VALUES (1, 'p1');
INSERT INTO PARENT VALUES (2, 'p2');
INSERT INTO TPARENT VALUES ('a');
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

pquery() { # <sql> <port> <db> <json-args>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" FC_ARGS="$4" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
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
# a PARAMETERISED statement, answered alike and driving a band built at
# EXECUTE - the trace says "(deferred)" for those
pboth() { # <label> <sql> <json-args> <want-deferred: yes|no>
    ran=$((ran + 1))
    before=$(grep -c "(deferred)" "$LOG" 2>/dev/null || true)
    a=$(pquery "$2" "$PORT" "$A" "$3")
    b=$(pquery "$2" "$REAL" "$B" "$3")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1
    fi
    after=$(grep -c "(deferred)" "$LOG" 2>/dev/null || true)
    ran=$((ran + 1))
    if [ "$4" = yes ] && [ "$after" -gt "$before" ]; then
        echo "OK   ... and its band was built at EXECUTE"
    elif [ "$4" = no ] && [ "$after" -eq "$before" ]; then
        echo "OK   ... and it scanned, as it must"
    else
        echo "DIFF $1: deferred=$4 but the log says otherwise"
        fail=1
    fi
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
# An AGGREGATE reads its input through a retrieval like anything else -
# the fold sits ABOVE the leaf, so the leaf is chosen the same way. Both
# the prepare-time scalar path and the grouped one go through it.
indexed "... counted" "SELECT COUNT(*) AS K FROM EMP WHERE DEPT_ID = 1"
indexed "... summed" "SELECT SUM(SALARY) AS S FROM EMP WHERE DEPT_ID = 1"
indexed "... the largest of them" "SELECT MAX(SALARY) AS M FROM EMP WHERE DEPT_ID = 1"
indexed "... a counted COLUMN, which skips NULLs" \
        "SELECT COUNT(SALARY) AS K FROM EMP WHERE DEPT_ID = 1"
indexed "an aggregate over a RANGE" "SELECT COUNT(*) AS K FROM EMP WHERE ID > 2"
indexed "a GROUPED query with an indexed WHERE" \
        "SELECT DEPT_ID, COUNT(*) AS K FROM EMP WHERE DEPT_ID = 1 GROUP BY DEPT_ID"
indexed "a GROUPED query over a range" \
        "SELECT DEPT_ID, COUNT(*) AS K FROM EMP WHERE ID > 1
         GROUP BY DEPT_ID ORDER BY DEPT_ID"
# The retrieval inherits the OPTIMIZER'S OWN LIMITS: opt does not parse
# a HAVING clause, so it declines the whole statement and this scans -
# even though the WHERE is the same indexable predicate as the check
# above. That is the right way round (a component that cannot read the
# statement must not be asked to bless it), and it is checked rather
# than assumed, so the day opt learns HAVING this check is what notices.
natural "... with a HAVING above it, which opt does not parse" \
        "SELECT DEPT_ID, COUNT(*) AS K FROM EMP WHERE ID > 1
         GROUP BY DEPT_ID HAVING COUNT(*) > 1 ORDER BY DEPT_ID"
natural "an aggregate with NO predicate" "SELECT COUNT(*) AS K FROM EMP"
natural "a GROUPED query with no predicate" \
        "SELECT DEPT_ID, COUNT(*) AS K FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
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
# these order by a column with NO index, so nothing but the PREDICATE
# could drive a retrieval - which is what each one is asking about
natural "no predicate at all" "SELECT ID FROM EMP ORDER BY NAME"
indexed "an OR of two equalities on the primary key" \
        "SELECT ID FROM EMP WHERE ID = 1 OR ID = 2 ORDER BY ID"
# A LONG list. `x IN (v1, ..., vn)` is n ORed equalities, and the DNF cap
# that bounds the AND CROSS-PRODUCT had been bounding this ADDITIVE
# growth too - so a list of 65 values was refused on a statement the
# engine answers. The multiplicative bound is still 64; the additive one
# is its own, and much larger.
# It ANSWERS; whether it drives an index is opt's call, and opt does not
# plan a long IN list - the retrieval inherits its limits, as everywhere
# else. The assertion is the answer.
both "an IN list of 70 values, past the old cap" \
        "SELECT COUNT(*) AS K FROM EMP WHERE ID IN (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70)"
both "... the same length over a column with no index" \
     "SELECT COUNT(*) AS K FROM EMP WHERE SALARY IN (100,200,300,400,50,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66)"
both "a cross-product of ORs stays bounded" \
     "SELECT COUNT(*) AS K FROM EMP WHERE (ID = 1 OR ID = 2) AND (DEPT_ID = 1 OR DEPT_ID = 2)"
natural "a NOT EQUAL" "SELECT ID FROM EMP WHERE ID <> 3 ORDER BY NAME"
natural "an equality on the SECOND segment of a compound index" \
        "SELECT ID FROM EMP WHERE SALARY = 200 ORDER BY NAME"
# the types whose key encoding this slice does not build
# BIGINT and SMALLINT are keyed too - the encoding is the WRITE path's
# own (int64 key for one, the double-form numeric key for the other),
# gated byte-exact against `compress` long before this slice
indexed "a BIGINT key" "SELECT T FROM WIDE WHERE K = 9000000000 ORDER BY T"
indexed "a NEGATIVE BIGINT key" "SELECT T FROM WIDE WHERE K = -9000000000"
indexed "the LARGEST BIGINT key" "SELECT T FROM WIDE WHERE K = 9223372036854775807"
# i64::MIN is the ONE value whose key cannot be built the way the engine
# built it: the engine's make_int64_key NEGATES the value before scaling
# it, and negating i64::MIN overflows, so its scale-control choice
# differs from the arithmetically correct one and our key lands
# elsewhere in the tree. Measured: this returned NOTHING where the
# engine returns its rows. A key that cannot be built exactly must SCAN,
# because the failure mode is a missed row rather than a refusal.
natural "i64::MIN, whose key the engine builds through an overflow" \
        "SELECT T FROM WIDE WHERE K = -9223372036854775808"
indexed "a SMALLINT key" "SELECT T FROM WIDE WHERE S = 7 ORDER BY T"
indexed "a NEGATIVE SMALLINT key" "SELECT T FROM WIDE WHERE S = -7"
natural "a SCALED numeric key" "SELECT T FROM WIDE WHERE N = 12.50 ORDER BY T"
# text WAS excluded here; it is keyed now (see the text section below),
# so this asserts the capability rather than its absence
indexed "a TEXT key" "SELECT K FROM WIDE WHERE T = 'aa'"


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
# A DESCENDING index is not keyed at all, and that is MEASURED rather
# than cautious. Its keys are complemented, which reverses byte order -
# so bounds must swap - but the complement also destroys the PREFIX
# relationship variable-length keys rely on: with 'ab' and 'abc' in one
# descending text index, an equality on 'ab' found NOTHING, and equality
# on a descending INTEGER index missed rows too. Two measured misses in
# one piece of arithmetic is enough.
# DS carries ONLY a descending index, so nothing else can serve these -
# on S, which has an ascending twin, the ascending one is used and the
# assertion would be about the wrong index.
natural "a range where only a DESCENDING index exists" \
        "SELECT T FROM WIDE WHERE DS > 2 ORDER BY T"
natural "... and the other way" "SELECT T FROM WIDE WHERE DS < 5 ORDER BY T"
natural "... and between" "SELECT T FROM WIDE WHERE DS BETWEEN 2 AND 5 ORDER BY T"
natural "EQUALITY on a descending integer index, which missed rows" \
        "SELECT T FROM WIDE WHERE DS = 4"
# on a column that ALSO has an ascending index, the ascending one serves
both "the ascending twin of a descending index still answers" \
     "SELECT T FROM WIDE WHERE S = 7 ORDER BY T"


# --- 3c. NAVIGATION: the sort an index makes unnecessary ---------------
# An index walk delivers its rows in KEY order, so a sort above it would
# re-establish an order that is already there. Dropping it is the
# engine's `Access::Order` - and it is the one place in this whole slice
# where getting it wrong does not lose a row but hands back the RIGHT
# rows in the WRONG ORDER, which a differential does catch, but only
# because row order is compared.
#
# The conditions are the ones that make the index's order TOTAL and
# equal to the clause: one ascending key, no explicit NULLS placement, a
# plain field, an ascending single-segment index that is UNIQUE, and a
# NOT NULL column (a unique index still admits several all-NULL keys,
# and duplicates come back in record-number order, which the engine has
# never promised).
navigated() { # <label> <sql> - answers like the engine AND skips the sort
    before=$(scans_since "navigate=true")
    both "$1" "$2"
    after=$(scans_since "navigate=true")
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and it NAVIGATED (no sort)"
    else
        echo "DIFF $1 did not navigate"
        fail=1
    fi
}
sorted_anyway() { # <label> <sql> - answers like the engine and SORTS
    before=$(scans_since "navigate=true")
    both "$1" "$2"
    after=$(scans_since "navigate=true")
    ran=$((ran + 1))
    if [ "$after" -eq "$before" ]; then
        echo "OK   ... and it sorted, as it must"
    else
        echo "DIFF $1 navigated an order the index does not deliver"
        fail=1
    fi
}
navigated "ORDER BY the primary key, with no predicate at all" \
          "SELECT ID, NAME FROM EMP ORDER BY ID"
navigated "... and with a range, which bounds the same walk" \
          "SELECT ID FROM EMP WHERE ID > 2 ORDER BY ID"
navigated "... under FIRST, where the order decides WHICH rows" \
          "SELECT FIRST 3 ID FROM EMP ORDER BY ID"
navigated "... and SKIP" "SELECT SKIP 2 ID FROM EMP ORDER BY ID"
# every one of these has an order the index does NOT deliver
sorted_anyway "DESCENDING - the walk goes the other way" \
              "SELECT ID FROM EMP ORDER BY ID DESC"
sorted_anyway "a NON-UNIQUE index - duplicates tie, and ties have no promised order" \
              "SELECT ID FROM EMP ORDER BY DEPT_ID, ID"
sorted_anyway "a column with no index" "SELECT ID FROM EMP ORDER BY NAME"
sorted_anyway "two keys, where the index has one" \
              "SELECT ID FROM EMP ORDER BY ID, NAME"
sorted_anyway "an explicit NULLS placement" \
              "SELECT ID FROM EMP ORDER BY ID NULLS LAST"
# a UNIQUE index on a NULLABLE column: all-NULL keys are exempt from
# uniqueness, so two rows can share the empty key and tie
sorted_anyway "a UNIQUE index on a NULLABLE column" \
              "SELECT V FROM NU ORDER BY K"
# and when the predicate's index is NOT the order's, the bounds win and
# the sort runs - reading a few records beats walking the whole relation
# to save a sort, which is opt's rule too
sorted_anyway "the predicate's index is not the order's" \
              "SELECT ID FROM EMP WHERE DEPT_ID = 1 ORDER BY ID"
# TEXT navigation. The index key is the stripped bytes, so the walk is
# in BYTE order - and for the DEFAULT collation that is the order the
# engine sorts by, case included ('' < 'A' < 'B' < 'a' < 'ab' < 'b').
# A column with a NON-default collation cannot reach here at all: its
# index carries an itype outside the accepted list, so no pick is built
# for the relation. The sequences below are the assertion.
navigated "ORDER BY a UNIQUE NOT NULL text column" \
          "SELECT N FROM TX ORDER BY S"
navigated "... under FIRST, where the order decides which rows" \
          "SELECT FIRST 3 N FROM TX ORDER BY S"
navigated "... and bounded by a text range" \
          "SELECT N FROM TX WHERE S >= '' ORDER BY S"


# --- 3d. COMPOUND INDEXES: an equality is a BAND, not a point ---------
# A compound key stuffs its segments together, so an equality on the
# LEADING segment names every key that begins with that prefix. The
# lower bound is the key of `(v, NULL, ...)` - which is exactly what the
# engine writes for that row, so it cannot miss the NULL-tailed ones -
# and the upper bound is that prefix's EXCLUSIVE SUCCESSOR.
#
# The successor is the whole slice. An INCLUSIVE bound at the prefix
# itself admits ONLY the all-NULL-tail key and silently drops every row
# that has a value in its trailing segments - a missed row, which no
# filter above can catch. Every check here has rows on both sides of
# that line.
indexed "an equality on the LEADING segment of a 2-segment index" \
        "SELECT C FROM CP WHERE A = 1 ORDER BY C"
indexed "... its NULL-tailed row is in the band" \
        "SELECT C FROM CP WHERE A = 1 AND B IS NULL"
indexed "... and so are the rows that have a trailing value" \
        "SELECT C FROM CP WHERE A = 1 AND B = 20"
indexed "a leading value with ONE row" "SELECT C FROM CP WHERE A = 2"
indexed "a NEGATIVE leading value, whose key carries 0xFF bytes" \
        "SELECT C FROM CP WHERE A = -1"
indexed "... and another" "SELECT C FROM CP WHERE A = -2"
indexed "ZERO as a leading value" "SELECT C FROM CP WHERE A = 0"
indexed "a leading value with no rows at all" "SELECT C FROM CP WHERE A = 42"
indexed "counted through the band" "SELECT COUNT(*) AS K FROM CP WHERE A = 1"
# what a compound index must NOT serve yet
natural "a RANGE on the leading segment - its own arithmetic per operator" \
        "SELECT C FROM CP WHERE A > 0 ORDER BY C"
natural "... and the inclusive one" "SELECT C FROM CP WHERE A <= 1 ORDER BY C"
natural "a predicate on a NON-leading segment" \
        "SELECT C FROM CP WHERE B = 10 ORDER BY C"

# --- 3e. TEXT KEYS -----------------------------------------------------
# The key strips trailing blanks on BOTH sides, which is the same
# pad-insensitivity the comparison has - so a CHAR value and a VARCHAR
# literal meet at the same key. A non-ASCII literal must SCAN: above
# 0x7F a charset or collation decides the bytes, and a key that differs
# from the stored one does not refuse, it misses.
indexed "text equality on a VARCHAR" "SELECT C FROM CP WHERE S = 'aa'"
indexed "... a value stored WITH trailing blanks" "SELECT C FROM CP WHERE S = 'dd'"
indexed "... and the literal carrying them instead" "SELECT C FROM CP WHERE S = 'dd  '"
indexed "the EMPTY string, whose key is a pad byte" "SELECT C FROM CP WHERE S = ''"
indexed "a text value that is not there" "SELECT C FROM CP WHERE S = 'zz'"
indexed "text equality on a CHAR, which pads" "SELECT C FROM CP WHERE KC = 'aa'"
indexed "... matched by a literal padded to the column's width" \
        "SELECT C FROM CP WHERE KC = 'aa    '"
natural "a NON-ASCII literal, which must not be keyed" \
        "SELECT C FROM CP WHERE S = 'ää'"
natural "IS NULL on a text column" "SELECT C FROM CP WHERE S IS NULL ORDER BY C"
natural "a text RANGE" "SELECT C FROM CP WHERE S > 'a' ORDER BY C"
# (iii) a DESCENDING text index holding a value that EXTENDS another:
# complementing the bytes destroys the prefix relationship, and the
# equality found nothing
natural "equality on a descending TEXT index, where one value extends another" \
        "SELECT ID FROM TD WHERE C = 'ab'"
natural "... and the longer one" "SELECT ID FROM TD WHERE C = 'abc'"


# --- 3f. A DUPLICATE RUN THAT SPANS LEAF PAGES ------------------------
# A non-leaf node's key is the LOWEST key of its child page, so when one
# value's duplicates span several leaf pages, SEVERAL non-leaf nodes
# carry that same key. A descent that advances while `key <= target`
# lands on the LAST of them and skips every earlier page that also holds
# it - 2306 of 2310 rows lost, and lost SILENTLY, because those rows
# never become candidates for the predicate to judge.
#
# Nothing in this gate could reach that: every other fixture here is a
# handful of rows, which is one leaf page. That is why these checks
# exist, and why they use 6000 identical keys.
indexed "a duplicate run spanning pages, through a compound band" \
        "SELECT COUNT(*) AS K, MIN(ID) AS LO, MAX(ID) AS HI FROM BIG WHERE A = 1"
indexed "... and through the single-segment index on the same column" \
        "SELECT COUNT(*) AS K FROM BIG WHERE A = 1 AND B IS NULL"
indexed "the short run beside it" \
        "SELECT COUNT(*) AS K, MIN(ID) AS LO FROM BIG WHERE A = 2"
indexed "a range that starts inside the long run" \
        "SELECT COUNT(*) AS K FROM BIG WHERE A >= 1"
indexed "a range that ends inside it" "SELECT COUNT(*) AS K FROM BIG WHERE A <= 1"
indexed "the FIRST rows of the run, in order" \
        "SELECT FIRST 3 ID FROM BIG WHERE A = 1 ORDER BY ID"
indexed "an aggregate over the whole run" \
        "SELECT SUM(ID) AS S FROM BIG WHERE A = 1"
indexed "grouped over it" \
        "SELECT A, COUNT(*) AS K FROM BIG WHERE A >= 1 GROUP BY A ORDER BY A"


# --- 3h. A PARAMETER'S VALUE ARRIVES AFTER THE PLAN -------------------
# `WHERE ID = ?` is how a prepared-statement client asks almost
# everything, and it could not reach an index at all: the band needs a
# value and the plan is built before there is one. The plan carries what
# `choose_index` cannot recover from a bound predicate - the table's
# name and the statement text opt reads - and the bands are built at
# EXECUTE, from the filter in which the `?` has become a literal.
pboth "an equality on a parameter" \
      "SELECT ID, NAME FROM EMP WHERE ID = ?" "[3]" yes
pboth "... one that matches nothing" \
      "SELECT ID FROM EMP WHERE ID = ?" "[99]" yes
pboth "a non-unique equality" \
      "SELECT ID FROM EMP WHERE DEPT_ID = ?" "[1]" yes
pboth "a range" "SELECT ID FROM EMP WHERE ID > ?" "[3]" yes
pboth "two bounds, two parameters" \
      "SELECT ID FROM EMP WHERE ID >= ? AND ID <= ?" "[2,4]" yes
pboth "an OR of two parameters" \
      "SELECT ID FROM EMP WHERE DEPT_ID = ? OR DEPT_ID = ?" "[1,2]" yes
pboth "a parameter on a column with no index" \
      "SELECT ID FROM EMP WHERE SALARY = ?" "[300]" no
pboth "a parameter beside a literal" \
      "SELECT ID FROM EMP WHERE DEPT_ID = ? AND SALARY > 100" "[1]" yes
pboth "a NULL parameter, which matches nothing" \
      "SELECT ID FROM EMP WHERE DEPT_ID = ?" "[null]" no

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



# --- 5c. A ROW THAT MOVED - the failure this section exists for --------
# An index entry OUTLIVES the version that wrote it: an UPDATE adds the
# new key and leaves the old one for garbage collection. So a record
# whose key changed is named by BOTH entries, and a RANGE that covers
# both fetches it TWICE - the predicate cannot catch that, because the
# row genuinely matches. In a NAVIGATING retrieval it is worse: the row
# also appears at the OLD key's position, so the order is wrong too.
#
# This was live for two increments (ranges, then navigation) and no gate
# caught it, because none of them changed a key column and then asked a
# question whose range spanned both keys. Every check below does.
both "move a row's key to the far end" "UPDATE EMP SET ID = 40 WHERE ID = 2"
both "... a full walk returns it ONCE, in its new place" \
     "SELECT ID FROM EMP ORDER BY ID"
both "... and so does a range covering both keys" \
     "SELECT ID FROM EMP WHERE ID > 0 ORDER BY ID"
both "... counted" "SELECT COUNT(*) AS K FROM EMP WHERE ID > 0"
both "... the OLD key finds nothing" "SELECT ID FROM EMP WHERE ID = 2"
both "... the NEW key finds one row" "SELECT ID FROM EMP WHERE ID = 40"
both "move it back" "UPDATE EMP SET ID = 2 WHERE ID = 40"
both "... and the walk is stable again" "SELECT ID FROM EMP ORDER BY ID"
# the same for a non-unique index, where the row moves between groups
both "move a row between groups" "UPDATE EMP SET DEPT_ID = 7 WHERE ID = 3"
both "... the old group no longer holds it" \
     "SELECT ID FROM EMP WHERE DEPT_ID = 2 ORDER BY ID"
both "... the new one does, once" "SELECT ID FROM EMP WHERE DEPT_ID = 7"
both "... and a range over the whole column is unchanged in size" \
     "SELECT COUNT(*) AS K FROM EMP WHERE DEPT_ID > -100"
# and a DELETE whose target was found through an index
both "delete through an index, then walk" "DELETE FROM EMP WHERE ID = 6"
both "... the walk agrees" "SELECT ID FROM EMP ORDER BY ID"

# --- 5b. THE FOREIGN KEY CHECK, which scanned once per written row -----
# `does a parent row with this key exist` is an EXISTENCE test, and the
# referenced side always carries a UNIQUE index because SQL requires one.
# It had been answered by scanning the whole referenced relation for
# EVERY row written. The whole key is known here, so a compound key is a
# point lookup rather than a prefix range - the one place a
# multi-segment index is the easy case.
# Both servers must REFUSE, but their messages differ: fire-crab has no
# constraint-violation text of its own yet (it raises a generic Dynamic
# SQL Error where the engine names the constraint and the offending
# key). That is a pre-existing gap, unchanged by this slice, so these
# assert the refusal on both sides rather than pretending the wording
# matches.
both_refuse() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    case "$a" in
        ERR*) ;;
        *) echo "DIFF $1: fire-crab ANSWERED [$a] where the engine raises"; fail=1; return ;;
    esac
    case "$b" in
        ERR*) echo "OK   refused by both: $1" ;;
        *) echo "DIFF $1: the ENGINE answered [$b] - this must not be refused"; fail=1 ;;
    esac
}
fk_lookups() { grep -c "fk lookup:" "$LOG" 2>/dev/null || true; }
fk_indexed() { # <label> <sql>
    before=$(fk_lookups)
    both "$1" "$2"
    after=$(fk_lookups)
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and the FK check used the parent's INDEX"
    else
        echo "DIFF $1 scanned the parent relation"
        fail=1
    fi
}
fk_scans() { # <label> <sql>
    before=$(fk_lookups)
    both "$1" "$2"
    after=$(fk_lookups)
    ran=$((ran + 1))
    if [ "$after" -eq "$before" ]; then
        echo "OK   ... and the FK check scanned, as it must"
    else
        echo "DIFF $1 keyed a lookup it cannot build exactly"
        fail=1
    fi
}
fk_indexed "a child row whose parent EXISTS" "INSERT INTO CHILD VALUES (1, 1)"
fk_indexed "another one, same parent" "INSERT INTO CHILD VALUES (2, 1)"
before=$(fk_lookups)
both_refuse "a child row whose parent does NOT exist" \
            "INSERT INTO CHILD VALUES (3, 99)"
ran=$((ran + 1))
if [ "$(fk_lookups)" -gt "$before" ]; then
    echo "OK   ... and the refusal came from an INDEX lookup, not a scan"
else
    echo "DIFF the failing FK check scanned the parent relation"; fail=1
fi
both "... and the refusal left no row behind" \
     "SELECT COUNT(*) AS K FROM CHILD"
# a NULL FK column passes without any check at all (MATCH SIMPLE)
both "a NULL foreign key needs no parent" "INSERT INTO CHILD VALUES (4, NULL)"
both "the child table, after all of it" "SELECT ID, PK FROM CHILD ORDER BY ID"
# the parent side: a key still referenced may not be deleted
both_refuse "deleting a referenced parent" "DELETE FROM PARENT WHERE K = 1"
both "deleting an UNreferenced parent is allowed" "DELETE FROM PARENT WHERE K = 2"
# a TEXT key cannot be built byte-exactly here, so it must still scan -
# and it must still be RIGHT
fk_scans "a TEXT foreign key, which scans" "INSERT INTO TCHILD VALUES (1, 'a')"
both_refuse "a TEXT key with no parent" "INSERT INTO TCHILD VALUES (2, 'zz')"
both "the text child table" "SELECT ID, PK FROM TCHILD ORDER BY ID"


# --- 5d. WHAT AN ADVERSARIAL FLEET FOUND ------------------------------
# Four failures that no fixture here could produce, each reduced to the
# smallest table that shows it. They are grouped because they share a
# cause: a record number is not a position, and an index entry is not a
# row.
#
# (i) A DELETED ROW MOVED EVERY LATER ROW OUT OF REACH. A record number
# names its page by SEQUENCE, and the sequence is not the page's
# POSITION in the relation's page list - a freed page leaves a gap. The
# lookup read the wrong page, failed its own sanity check, and dropped
# the row: one deleted row hid every key stored after it.
both "delete one row" "DELETE FROM DEL WHERE ID = 1"
both "... every later key is still reachable" \
     "SELECT COUNT(*) AS C FROM DEL WHERE K = 20"
both "... and by their own values" "SELECT ID, K FROM DEL WHERE K = 20 ORDER BY ID"
both "... and the whole table agrees" "SELECT ID, K FROM DEL ORDER BY ID"
#
# (ii) A KEY THAT LEAVES AND COMES BACK was returned TWICE. The writer
# skips an entry it already holds, but only within the leaf page it
# descended to - so a key can end up with two identical entries in
# different pages, both of them CURRENT. Verification cannot separate
# them; only one row per record can.
both "move a key away" "UPDATE DEL SET K = 25 WHERE ID = 2"
both "... and bring it back" "UPDATE DEL SET K = 20 WHERE ID = 2"
both "... the row comes back ONCE" "SELECT ID, K FROM DEL WHERE K = 20 ORDER BY ID"
both "... counted once" "SELECT COUNT(*) AS C FROM DEL WHERE K = 20"
both "... and summed once" "SELECT SUM(K) AS S FROM DEL WHERE K >= 0"


# (iii) A GARBAGE-COLLECTED SLOT SHIFTED EVERY LATER RECORD. The fixture
# deleted one row through the ENGINE and then read the table, which
# collects the dead version and RELEASES its slot. `DataPage::records()`
# filters released slots out, so taking the nth survivor is not the
# record at slot n: every entry after the hole fetched someone else's
# record - a WRONG row, not a missing one, and a wrong row can satisfy
# the predicate and be returned or written.
indexed "after an engine-side delete and collection, the count is right" \
        "SELECT COUNT(*) AS C FROM GC WHERE K = 20"
indexed "... and the rows are the right ones" \
        "SELECT ID, K FROM GC WHERE K = 20 ORDER BY ID"
indexed "... including the one whose slot moved" "SELECT ID FROM GC WHERE ID = 3"
both "... and the whole table agrees" "SELECT ID, K FROM GC ORDER BY ID"
#
# (iv) A KEY THAT LEFT AND CAME BACK INSIDE ONE ENGINE TRANSACTION
# leaves TWO live entries with the same (key, record) pair - the one the
# INSERT wrote and the one the second UPDATE wrote. Both are current, so
# verifying the key cannot separate them; only one row per record can.
# fire-crab doing the same writes does NOT produce this - it needs the
# engine's own same-transaction index maintenance, which is what a
# stored procedure touching a column twice will produce.
indexed "a key that left and came back answers ONCE" \
        "SELECT ID, K FROM RT WHERE K = 10"
indexed "... counted once" "SELECT COUNT(*) AS C FROM RT WHERE K = 10"
indexed "... summed once" "SELECT SUM(K) AS S FROM RT WHERE K >= 0"
navigated "... and a navigated order is not shifted by it" \
          "SELECT FIRST 2 ID FROM RT ORDER BY ID"


# --- 5e. AN ENTRY THE SERVER CANNOT JUDGE ------------------------------
# A candidate is kept only if the fetched record STILL CARRIES the
# entry's key - which means REBUILDING the key from the record. When
# that rebuild FAILS, the check has nothing to say, and it must
# therefore say nothing: answering "stale" DROPS the row.
#
# It dropped a lot. A FLOAT column anywhere in an index made every
# retrieval over that index return the EMPTY SET (a FLOAT decodes to a
# value the key encoder does not take). A scaled DECIMAL lost most of
# its values. And i64::MIN came back through this door after the
# search-key guard had already closed the other one.
#
# The predicate above still decides and the record-number dedup still
# collapses duplicates, so an unjudgeable candidate costs a comparison.
# Dropping one costs a row.
indexed "a row beside a scaled DECIMAL column" "SELECT ID FROM UNJ WHERE A = 3"
indexed "... and all of them" "SELECT COUNT(*) AS K FROM UNJ WHERE A >= 1"
# an index ON a scaled column cannot be keyed at all (the stored value
# is Scaled(raw, scale) and a literal would build a different key), so
# it scans - and must still be RIGHT
natural "an index ON the scaled column" "SELECT ID FROM UNJ WHERE D = 0.2"
indexed "a compound index holding a FLOAT segment" \
        "SELECT ID FROM UNJ WHERE A = 1 ORDER BY ID"
# a row holding i64::MIN in a column the retrieval does NOT key on: its
# entry in the OTHER index cannot be rebuilt, and dropping it for that
# reason is what the fail-open rule prevents. (The predicate compares
# against a value that is not i64::MIN - the engine's own comparison
# against i64::MIN differs from fire-crab's, which is a separate,
# pre-existing question and not this one.)
indexed "a row whose OTHER column holds i64::MIN" \
        "SELECT ID FROM UNJ WHERE A = 1 AND B > -5"
both "the whole table, whatever it is keyed by" "SELECT ID, A FROM UNJ ORDER BY ID"
# A SCALED value's key goes through MOV_get_double, which DIVIDES by the
# power of ten. Multiplying by 10^-n is a different double in the last
# ulp for about a third of the raws - 0.3, 0.6, 0.7, 1.2, 1.4, 1.7 among
# them - so the key was one the engine never wrote, and every row
# carrying such a value dropped out of the index that held it. These
# values are in the fixture on purpose.
indexed "a compound index whose second segment is a scaled DECIMAL" \
        "SELECT ID FROM UNJ WHERE A = 5"
indexed "... one of the other raws where multiply and divide disagree" \
        "SELECT ID FROM UNJ WHERE A = 6"
indexed "... and another" "SELECT ID FROM UNJ WHERE A = 7"
indexed "... all of them at once" \
        "SELECT COUNT(*) AS K FROM UNJ WHERE A = 5 OR A = 6 OR A = 7"
# a row holding i64::MIN in the very column the retrieval keys on: the
# key cannot be built faithfully, so the retrieval must ABSTAIN - both
# for the search key and for the candidate's verification - and the row
# must still come back
both "a range over a column holding i64::MIN" \
     "SELECT ID FROM SN WHERE BG <= 0 ORDER BY ID"
both "... and the whole column" "SELECT ID FROM SN ORDER BY ID"
# An INT128 key whose LAST 3-digit group is a multiple of 256 grew a
# trailing 0x00 byte the engine does not write - about 2 in 3000 random
# NUMERIC(38,6) values, which is why it took random full-range data to
# find. This value is one of them.
indexed "a compound band over NUMERIC(38,6), one value keyed a byte too long" \
        "SELECT ID FROM Z128 WHERE K = 1 ORDER BY ID"
indexed "... counted" "SELECT COUNT(*) AS C FROM Z128 WHERE K = 1"
# a compound band whose TRAILING segment holds i64::MIN, with no
# predicate on that column at all
indexed "a compound band whose trailing segment holds i64::MIN" \
        "SELECT ID FROM CTB WHERE K = 1 ORDER BY ID"

# --- 5f. ROW ORDER WITHOUT AN ORDER BY --------------------------------
# The engine's non-navigational retrieval ORs its branches into a
# RECORD-NUMBER BITMAP and hands rows back in RECORD order. Ours came
# back in band order, then key order within a band. With no ORDER BY
# that is an unordered result either way - until FIRST makes it a
# different SET OF ROWS.
both "FIRST over an OR, with no ORDER BY" \
     "SELECT FIRST 2 ID FROM EMP WHERE DEPT_ID = 2 OR DEPT_ID = 1"
both "... the branches the other way round" \
     "SELECT FIRST 2 ID FROM EMP WHERE DEPT_ID = 1 OR DEPT_ID = 2"
both "... and more of them" \
     "SELECT FIRST 3 ID FROM EMP WHERE DEPT_ID = 1 OR DEPT_ID = 2"
both "FIRST over a single band, with no ORDER BY" \
     "SELECT FIRST 2 ID FROM EMP WHERE DEPT_ID = 1"
both "SKIP over an OR" \
     "SELECT SKIP 1 ID FROM EMP WHERE DEPT_ID = 1 OR DEPT_ID = 2"

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
same_both_ways "a compound prefix band" "SELECT C FROM CP WHERE A = 1 ORDER BY C"
same_both_ways "a text equality" "SELECT C FROM CP WHERE S = 'aa'"
same_both_ways "an empty-string key" "SELECT C FROM CP WHERE S = ''"
same_both_ways "a navigated TEXT order, case included" "SELECT N FROM TX ORDER BY S"
same_both_ways "a duplicate run spanning leaf pages" \
               "SELECT COUNT(*) AS K, MIN(ID) AS LO FROM BIG WHERE A = 1"
same_both_ways "an aggregate" "SELECT COUNT(*) AS K FROM EMP WHERE DEPT_ID = 9"
# ORDER is part of the answer, so the navigating server and the sorting
# one must produce the same SEQUENCE, not just the same set
same_both_ways "a navigated order" "SELECT ID, NAME FROM EMP ORDER BY ID"
same_both_ways "a navigated order under a range" \
               "SELECT ID FROM EMP WHERE ID >= 2 ORDER BY ID"
same_both_ways "a navigated order under FIRST" \
               "SELECT FIRST 2 ID FROM EMP ORDER BY ID"
same_both_ways "a grouped query" \
               "SELECT DEPT_ID, COUNT(*) AS K FROM EMP WHERE ID > 1
                GROUP BY DEPT_ID ORDER BY DEPT_ID"
# and the switch really did switch it off
ran=$((ran + 1))
if [ "$(grep -c 'index scan:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   the scan-only server drove NO index (so the checks above can fail)"
else
    echo "DIFF FC_NO_INDEX did not disable the index path - the coverage checks prove nothing"
    fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 236 ]; then
    echo "DIFF only $ran checks ran (expected at least 236) - did one silently skip?"
    fail=1
fi
exit $fail
