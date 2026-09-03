#!/bin/bash
# REFERENTIAL ACTIONS, EXECUTED BY THE SERVER UNDER TEST - the half
# qa/serve-real-fkcascade.sh does not reach.
#
# That gate proves fire-crab WRITES the right trigger (BLR byte for byte,
# RDB$RUNTIME byte for byte) and that the ENGINE, reading fire-crab's
# file, RUNS it. It never asks whether fire-crab runs it. It does not:
# measured 2026-09-03, a parent whose child declares ON DELETE CASCADE is
# entirely UNDELETABLE through fire-crab - every DELETE fails at prepare
# with a bare `Dynamic SQL Error`, including a DELETE of a row that has
# no children at all. Same for ON DELETE SET NULL, ON UPDATE CASCADE,
# ON UPDATE SET NULL and ON UPDATE SET DEFAULT.
#
# The engine's laws, measured one parent and one child per action so that
# no two foreign keys can confound each other:
#
#   ON DELETE CASCADE       the child row is DELETED
#   ON DELETE SET NULL      the child is kept, its FK column becomes NULL
#   ON DELETE SET DEFAULT   the child is kept, its FK column becomes the
#                           COLUMN's DEFAULT (not zero, not the parent value)
#   ON UPDATE CASCADE       the child's FK column becomes the parent's NEW value
#   ON UPDATE SET NULL      ... becomes NULL
#   ON UPDATE SET DEFAULT   ... becomes the column's DEFAULT
#   no action declared      the DELETE/UPDATE is REFUSED, SQLSTATE 23000:
#     violation of FOREIGN KEY constraint "<c>" on table "PUBLIC"."<child>"
#     -Foreign key references are present for the record
#     -Problematic key value is ("<parent col>" = <value>)
#   (the message names the CHILD's table and constraint, but the
#    problematic value is the PARENT's column and value)
#
# Every action gets its OWN parent and child here, deliberately: with
# several children of one parent the engine CHECKS only ONE of them per
# referenced index and this server checks them ALL (section 13, the
# deliberate divergence), so a shared parent would measure that
# difference instead of the action.
#
#   qa/serve-real-fkaction.sh [port]
#
# Builds its own scratch databases (one written by fire-crab, one by the
# engine) and compares what each server ANSWERS and what rows each file
# then HOLDS, as read back by the ENGINE.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4172}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-fkact-crab.fdb"
B="$D/fc-fkact-engine.fdb"
LOG="/tmp/fc-serve-fkact-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

mk_empty() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE 'localhost:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null; return 0; }
mk_empty "$A" || { echo "FAIL scratch A"; exit 1; }
mk_empty "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
# THE PID OF THE SERVER THIS GATE STARTED, and the ONE name that holds
# it. It used to be called `srv`, and a `for srv in "$PORT:$A:..."` loop
# 350 lines below overwrote it with a STRING, so the EXIT trap ran
# `kill 3050:/tmp/fbhandson/fc-fkact-engine.fdb:engine`, which fails, and
# every run of this gate left a listening fcwire behind on a shared box.
# Measured 2026-09-03 before the rename: the gate prints `rc=0` and
# `ps -eo pid,args` still shows `fcwire serve 127.0.0.1:<port>`; after
# it, two consecutive runs on the SAME port both start clean and neither
# leaves a process. Do not reuse this name, and do not kill by PORT: an
# earlier session's `pkill` on a port matched its own shell and, later,
# a server belonging to somebody else. Kill BY PID, which is what
# `cleanup` does.
FKACT_SRV_PID=$!
# every exit path goes through here - the ordinary end, a failed early
# return, and a signal - and each one kills what this script started
cleanup() {
    rc=$?
    if [ -n "${FKACT_SRV_PID:-}" ]; then
        kill "$FKACT_SRV_PID" 2>/dev/null
        wait "$FKACT_SRV_PID" 2>/dev/null
    fi
    rm -f "$A" "$B"
    exit $rc
}
trap cleanup EXIT INT TERM HUP
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 "$FKACT_SRV_PID" 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# run one script through EACH server, on its own file, and compare what
# each ANSWERS - the refusals included, message text and all
both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
# what the ENGINE reads back from each file - the only judge of what the
# action actually did to the rows
eboth() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# ---- THE DELIBERATE DIVERGENCE, ASSERTED RATHER THAN SKIPPED ----------
# fire-crab checks EVERY foreign-key partnership on a parent DELETE or
# UPDATE. The ENGINE checks ONE per referenced index - the first
# RDB$INDICES row naming it, in PHYSICAL RECORD ORDER - and performs the
# statement with the partnerships behind it still holding the key, which
# leaves a DANGLING CHILD ROW in the engine's own file. The decision,
# its reason and its exact consequence are in docs/roadmap.md and on
# fk_check_parent_row in crates/wire/src/server.rs.
#
# A gate that quietly stopped comparing here would be worse than one
# that fails, so nothing is skipped: every diverging shape asserts
# BOTH servers' answers against a recorded expectation, plus the
# DIRECTION (in THESE shapes only fire-crab refuses), plus what the
# ENGINE reads back out of each file - fire-crab's with no orphan in
# it, the engine's with the orphan it left. If either server changes
# its mind, this FAILS.
#
# THE SCOPE OF THAT DIRECTION: it is asserted here shape by shape, not
# as a law. The direction holds where the ENGINE'S SELECTOR is what
# differs, which is what section 13 is about. It does NOT hold
# everywhere: where a SIBLING partnership's action has already cleared
# the rows this one probes, the engine's file is clean and fire-crab
# over-refuses, and a BEFORE UPDATE trigger that moves the referenced
# key escapes the SET-list narrowing before the walk is reached and
# fire-crab performs what the engine refuses. Both are pre-existing,
# both are recorded in docs/roadmap.md, and neither is asserted here.
crabq()   { printf 'SET LIST ON;\n%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm; }
engineq() { printf 'SET LIST ON;\n%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm; }
efileq()  { printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$1" 2>&1 | norm; }
refused() { case "$1" in *"SQLSTATE = 23000"*) echo refuses;; *) echo performs;; esac; }
# label, sql, the answer fire-crab must give, the answer the ENGINE gives
diverge() {
    dc=$(crabq "$2"); de=$(engineq "$2")
    check "$1 - fire-crab REFUSES" "$dc" "$3"
    check "$1 - the ENGINE performs it (recorded, not compared)" "$de" "$4"
    check "$1 - the direction: only fire-crab refuses" \
          "crab-$(refused "$dc")|engine-$(refused "$de")" "crab-refuses|engine-performs"
}
# label, sql, what the ENGINE reads out of fire-crab's file (no orphan),
# what it reads out of its own (the orphan)
noorphan() {
    check "$1 - the ENGINE reads fire-crab's file: NO dangling child" "$(efileq "$A" "$2")" "$3"
    check "$1 - the ENGINE reads its OWN file: the dangling child" "$(efileq "$B" "$2")" "$4"
}
# label, sql, the answer fire-crab must give, the answer the ENGINE
# gives - for a shape where the ROWS agree and the two differ only by a
# KNOWN, RECORDED message gap. BOTH sides are pinned, so neither server
# can change its mind unnoticed; this is not a way to stop comparing.
gap() {
    check "$1 - fire-crab's answer (a recorded message gap)" "$(crabq "$2")" "$3"
    check "$1 - the ENGINE's own answer" "$(engineq "$2")" "$4"
}
# the same two reads where what differs is the CATALOG, not the rows -
# both sides pinned, so a change in either file's layout FAILS here
efiles() {
    check "$1 - in fire-crab's file" "$(efileq "$A" "$2")" "$3"
    check "$1 - in the ENGINE's file" "$(efileq "$B" "$2")" "$4"
}

# ---- 1. one parent and one child per action ----------------------------------
for spec in "DC:ON DELETE CASCADE" "DN:ON DELETE SET NULL" "DD:ON DELETE SET DEFAULT" \
            "UC:ON UPDATE CASCADE" "UN:ON UPDATE SET NULL" "UD:ON UPDATE SET DEFAULT" \
            "NA:"; do
    n="${spec%%:*}"; act="${spec#*:}"
    both "schema for $n (${act:-no action declared})" \
         "CREATE TABLE P$n (ID INTEGER NOT NULL PRIMARY KEY);
          CREATE TABLE C$n (A INTEGER, B INTEGER DEFAULT 7 REFERENCES P$n $act);
          COMMIT;
          INSERT INTO P$n VALUES (1); INSERT INTO P$n VALUES (7); COMMIT;
          INSERT INTO C$n VALUES (10, 1); INSERT INTO C$n VALUES (11, 7); COMMIT;
          SELECT COUNT(*) NP FROM P$n; SELECT COUNT(*) NC FROM C$n;"
done

# ---- 2. the DELETE actions ---------------------------------------------------
for n in DC DN DD NA; do
    both "DELETE the referenced parent row, $n" \
         "DELETE FROM P$n WHERE ID = 1; COMMIT;
          SELECT COUNT(*) NP FROM P$n; SELECT A, B FROM C$n ORDER BY A;"
    eboth "... and the ENGINE reads the same rows out of each file, $n" \
          "SELECT COUNT(*) NP FROM P$n; SELECT A, B FROM C$n ORDER BY A;"
done

# ---- 3. the UPDATE actions ---------------------------------------------------
for n in UC UN UD; do
    both "UPDATE the referenced parent key, $n" \
         "UPDATE P$n SET ID = 99 WHERE ID = 1; COMMIT;
          SELECT ID FROM P$n ORDER BY ID; SELECT A, B FROM C$n ORDER BY A;"
    eboth "... and the ENGINE reads the same rows out of each file, $n" \
          "SELECT ID FROM P$n ORDER BY ID; SELECT A, B FROM C$n ORDER BY A;"
done
both "UPDATE the referenced parent key with no action declared, NA" \
     "UPDATE PNA SET ID = 98 WHERE ID = 1; COMMIT;
      SELECT ID FROM PNA ORDER BY ID; SELECT A, B FROM CNA ORDER BY A;"

# ---- 4. a parent row with NO children at all ---------------------------------
# the shape that proves the refusal is about the ROW and not the TABLE:
# fire-crab refused this one too, which is how the defect was found
both "a parent row with no children deletes, whatever the action" \
     "DELETE FROM PDC WHERE ID = 7; COMMIT; SELECT COUNT(*) N FROM PDC;
      DELETE FROM PNA WHERE ID = 7; COMMIT; SELECT COUNT(*) N FROM PNA;"

# ---- 5. the actions through the TABLE-LEVEL spelling --------------------------
both "the table-level spelling behaves identically" \
     "CREATE TABLE PT (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE CT (A INTEGER, B INTEGER, FOREIGN KEY (B) REFERENCES PT ON DELETE CASCADE);
      COMMIT;
      INSERT INTO PT VALUES (1); INSERT INTO PT VALUES (2); COMMIT;
      INSERT INTO CT VALUES (10, 1); COMMIT;
      DELETE FROM PT WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM PT; SELECT COUNT(*) NC FROM CT;"

# ---- 6. an UPDATE that does not change the key ---------------------------------
# the engine's ON UPDATE trigger is guarded by IF OLD.pk <> NEW.pk, so an
# UPDATE that leaves the key alone must touch no child
both "an UPDATE that leaves the key alone touches no child" \
     "CREATE TABLE PS (ID INTEGER NOT NULL PRIMARY KEY, T VARCHAR(5));
      CREATE TABLE CS (A INTEGER, B INTEGER REFERENCES PS ON UPDATE SET NULL);
      COMMIT;
      INSERT INTO PS VALUES (1, 'x'); COMMIT;
      INSERT INTO CS VALUES (10, 1); COMMIT;
      UPDATE PS SET T = 'y' WHERE ID = 1; COMMIT;
      UPDATE PS SET ID = 1 WHERE ID = 1; COMMIT;
      SELECT A, B FROM CS ORDER BY A;"

# ---- 7. several children of one parent ---------------------------------------
# Every acting partnership fires its action - and M3, which declares only
# an ON UPDATE rule, is an ordinary RESTRICT partner on a DELETE and still
# holds the key. This server asks it and REFUSES; the engine asks only M1
# (the first RDB$INDICES row on this index), whose cascade clears its own
# rows, and DELETES the parent with M3's row left dangling at 1. Section
# 13 is the decision; this is its first sighting in an ordinary shape.
diverge "several children of one parent, on a parent DELETE" \
     "CREATE TABLE PM (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE M1 (A INTEGER, B INTEGER REFERENCES PM ON DELETE CASCADE);
      CREATE TABLE M2 (A INTEGER, B INTEGER REFERENCES PM ON DELETE SET NULL);
      CREATE TABLE M3 (A INTEGER, B INTEGER REFERENCES PM ON UPDATE CASCADE);
      COMMIT;
      INSERT INTO PM VALUES (1); COMMIT;
      INSERT INTO M1 VALUES (10, 1); INSERT INTO M2 VALUES (20, 1); INSERT INTO M3 VALUES (30, 1); COMMIT;
      DELETE FROM PM WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM PM; SELECT COUNT(*) N1 FROM M1;
      SELECT A, B FROM M2 ORDER BY A; SELECT A, B FROM M3 ORDER BY A;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_32" on table "PUBLIC"."M3"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 1)|NP 1|N1 1|A 20|B 1|A 30|B 1|' \
     'NP 0|N1 0|A 20|B <null>|A 30|B 1|'
noorphan "several children of one parent" \
     "SELECT COUNT(*) NP FROM PM; SELECT A, B FROM M2 ORDER BY A; SELECT A, B FROM M3 ORDER BY A;" \
     'NP 1|A 20|B 1|A 30|B 1|' \
     'NP 0|A 20|B <null>|A 30|B 1|'

# ---- 8. AN ACTION FIRES ONLY WHEN ITS COMPARISON IS TRUE ---------------------
# The engine's synthesised ON UPDATE body is `IF (OLD.k <> NEW.k [OR ...])`
# and `<>` against NULL is UNKNOWN, not TRUE. So a new key of NULL fires
# NOTHING and the statement meets the ordinary master-side refusal
# instead - measured 2026-09-03 against the engine, all four update rules
# with one child row present. Performing the action there wrote a child
# row the engine never wrote, and gfix called the file clean: a REFUSAL
# turned into a SILENT WRONG WRITE, which is why this section exists.
for spec in "NC:ON UPDATE CASCADE" "NN:ON UPDATE SET NULL" \
            "ND:ON UPDATE SET DEFAULT" "NX:"; do
    n="${spec%%:*}"; act="${spec#*:}"
    both "a new key of NULL takes the RESTRICT path, $n (${act:-no rule})" \
         "CREATE TABLE P$n (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
          CREATE TABLE C$n (X INTEGER, B INTEGER DEFAULT 5 REFERENCES P$n (U) $act);
          COMMIT;
          INSERT INTO P$n VALUES (1, 10); INSERT INTO P$n VALUES (2, 5); COMMIT;
          INSERT INTO C$n VALUES (100, 10); COMMIT;
          UPDATE P$n SET U = NULL WHERE ID = 1; COMMIT;
          SELECT ID, U FROM P$n ORDER BY ID; SELECT X, B FROM C$n ORDER BY X;"
    eboth "... and the ENGINE reads the same rows out of each file, $n" \
          "SELECT ID, U FROM P$n ORDER BY ID; SELECT X, B FROM C$n ORDER BY X;"
done
# ...and it must NOT become a blanket refusal: with NO CHILD the same
# statement succeeds on both servers, under every rule
for spec in "KC:ON UPDATE CASCADE" "KN:ON UPDATE SET NULL" \
            "KD:ON UPDATE SET DEFAULT" "KX:"; do
    n="${spec%%:*}"; act="${spec#*:}"
    both "a new key of NULL with NO children still succeeds, $n (${act:-no rule})" \
         "CREATE TABLE P$n (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
          CREATE TABLE C$n (X INTEGER, B INTEGER DEFAULT 5 REFERENCES P$n (U) $act);
          COMMIT;
          INSERT INTO P$n VALUES (1, 10); COMMIT;
          UPDATE P$n SET U = NULL WHERE ID = 1; COMMIT;
          SELECT ID, U FROM P$n; SELECT COUNT(*) NC FROM C$n;"
done
# a child whose OWN key is NULL references nothing (MATCH SIMPLE), so the
# parent key may still go NULL
both "a child holding a NULL key does not hold the parent back" \
     "CREATE TABLE PVN (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE CVN (X INTEGER, B INTEGER REFERENCES PVN (U) ON UPDATE CASCADE);
      COMMIT; INSERT INTO PVN VALUES (1, 10); COMMIT;
      INSERT INTO CVN VALUES (100, NULL); COMMIT;
      UPDATE PVN SET U = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U FROM PVN; SELECT X, B FROM CVN;"

# ---- 9. MULTI-COLUMN: the OR is what decides, not "any NULL" ------------------
# With a two-column key the engine PERFORMS an update in which one column
# really changed and the other went NULL (one comparison is TRUE), and
# REFUSES one in which no comparison is TRUE. A blanket "any NULL in the
# new key refuses" would be its own regression - it would refuse the
# first two of these four, which the engine performs.
mc_n=0
for spec in "ON UPDATE CASCADE|U1 = 11, U2 = NULL" \
            "ON UPDATE SET NULL|U1 = NULL, U2 = 21" \
            "ON UPDATE SET DEFAULT|U1 = NULL, U2 = 21" \
            "ON UPDATE CASCADE|U1 = 10, U2 = NULL" \
            "ON UPDATE SET NULL|U1 = 10, U2 = NULL" \
            "ON UPDATE SET DEFAULT|U1 = 10, U2 = NULL" \
            "ON UPDATE CASCADE|U1 = NULL, U2 = NULL" \
            "|U1 = 11, U2 = NULL"; do
    act="${spec%%|*}"; sets="${spec#*|}"; mc_n=$((mc_n + 1)); n="MK$mc_n"
    both "multi-column key [${act:-no rule}] SET $sets" \
         "CREATE TABLE P$n (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, UNIQUE (U1, U2));
          CREATE TABLE C$n (X INTEGER, B1 INTEGER DEFAULT 7, B2 INTEGER DEFAULT 8,
                            FOREIGN KEY (B1, B2) REFERENCES P$n (U1, U2) $act);
          COMMIT;
          INSERT INTO P$n VALUES (1, 10, 20); INSERT INTO P$n VALUES (2, 7, 8); COMMIT;
          INSERT INTO C$n VALUES (100, 10, 20); COMMIT;
          UPDATE P$n SET $sets WHERE ID = 1; COMMIT;
          SELECT ID, U1, U2 FROM P$n ORDER BY ID; SELECT X, B1, B2 FROM C$n ORDER BY X;"
    eboth "... and the ENGINE reads the same rows out of each file, $n" \
          "SELECT ID, U1, U2 FROM P$n ORDER BY ID; SELECT X, B1, B2 FROM C$n ORDER BY X;"
done

# ---- 10. the CHECKED partnership when the action does NOT fire ---------------
# A partnership whose action does not fire is CHECKED exactly as a
# no-rule one is - both servers agree on that, and it is what W1 and W3
# hold. W2 is the shape where the two part company: the non-firing
# partner in front is EMPTY, so the engine's one-per-index check passes
# on it and performs the UPDATE, leaving W2B pointing at a key that no
# longer exists. This server asks W2B too. Section 13 is the decision.
both "non-firing action partner (with rows) first: it refuses on its own children" \
     "CREATE TABLE PW1 (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE W1A (X INTEGER, B INTEGER REFERENCES PW1 (U) ON UPDATE CASCADE);
      CREATE TABLE W1B (X INTEGER, B INTEGER REFERENCES PW1 (U));
      COMMIT; INSERT INTO PW1 VALUES (1, 10); COMMIT;
      INSERT INTO W1A VALUES (100, 10); INSERT INTO W1B VALUES (200, 10); COMMIT;
      UPDATE PW1 SET U = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U FROM PW1; SELECT X, B FROM W1A; SELECT X, B FROM W1B;"
diverge "non-firing action partner (EMPTY) first: this server asks the one behind it" \
     "CREATE TABLE PW2 (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE W2A (X INTEGER, B INTEGER REFERENCES PW2 (U) ON UPDATE CASCADE);
      CREATE TABLE W2B (X INTEGER, B INTEGER REFERENCES PW2 (U));
      COMMIT; INSERT INTO PW2 VALUES (1, 10); COMMIT;
      INSERT INTO W2B VALUES (200, 10); COMMIT;
      UPDATE PW2 SET U = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U FROM PW2; SELECT X, B FROM W2B;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_110" on table "PUBLIC"."W2B"|-Foreign key references are present for the record|-Problematic key value is ("U" = 10)|ID 1|U 10|X 200|B 10|' \
     'ID 1|U <null>|X 200|B 10|'
noorphan "non-firing action partner (EMPTY) first (the UPDATE spelling)" \
     "SELECT ID, U FROM PW2; SELECT X, B FROM W2B;" \
     'ID 1|U 10|X 200|B 10|' \
     'ID 1|U <null>|X 200|B 10|'
both "two acting partners, the first EMPTY: both act when the guard fires" \
     "CREATE TABLE PW3 (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE W3A (X INTEGER, B INTEGER REFERENCES PW3 (U) ON UPDATE CASCADE);
      CREATE TABLE W3B (X INTEGER, B INTEGER REFERENCES PW3 (U) ON UPDATE CASCADE);
      COMMIT; INSERT INTO PW3 VALUES (1, 10); COMMIT;
      INSERT INTO W3B VALUES (200, 10); COMMIT;
      UPDATE PW3 SET U = 99 WHERE ID = 1; COMMIT;
      SELECT ID, U FROM PW3; SELECT X, B FROM W3A; SELECT X, B FROM W3B;"

# ---- 11. a PARTLY NULL parent key is still referenceable ---------------------
# The two sides are not the same law. The CHILD side is MATCH SIMPLE - a
# NULL component references nothing, which is how such a child row gets
# in. The MASTER side probes the child's INDEX, where a NULL is a
# storable key: parent (10, NULL) with child (10, NULL) IS referenced and
# the DELETE is REFUSED; parent (10, NULL) with child (NULL, NULL) is
# not. Only an ALL-NULL parent key is unreferenceable. The action never
# reaches such a child either - its WHERE is `child.k = OLD.k`, and `=`
# never matches a NULL.
pn_n=0
for spec in "|10, NULL|100, 10, NULL" \
            "ON DELETE CASCADE|10, NULL|100, 10, NULL" \
            "ON DELETE SET NULL|10, NULL|100, 10, NULL" \
            "ON DELETE CASCADE|NULL, 20|100, NULL, 20" \
            "ON DELETE CASCADE|10, NULL|100, NULL, NULL" \
            "ON DELETE CASCADE|NULL, NULL|100, NULL, NULL"; do
    act="${spec%%|*}"; rest="${spec#*|}"; pk="${rest%%|*}"; ck="${rest#*|}"
    pn_n=$((pn_n + 1)); n="PN$pn_n"
    both "partly-NULL parent key ($pk) child ($ck) [${act:-no rule}]" \
         "CREATE TABLE P$n (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, UNIQUE (U1, U2));
          CREATE TABLE C$n (X INTEGER, B1 INTEGER, B2 INTEGER,
                            FOREIGN KEY (B1, B2) REFERENCES P$n (U1, U2) $act);
          COMMIT; INSERT INTO P$n VALUES (1, $pk); COMMIT;
          INSERT INTO C$n VALUES ($ck); COMMIT;
          DELETE FROM P$n WHERE ID = 1; COMMIT;
          SELECT COUNT(*) NP FROM P$n; SELECT X, B1, B2 FROM C$n ORDER BY X;"
    eboth "... and the ENGINE reads the same rows out of each file, $n" \
          "SELECT COUNT(*) NP FROM P$n; SELECT X, B1, B2 FROM C$n ORDER BY X;"
done
both "an UPDATE of a partly-NULL parent key is refused the same way" \
     "CREATE TABLE PNU (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, UNIQUE (U1, U2));
      CREATE TABLE CNU (X INTEGER, B1 INTEGER, B2 INTEGER,
                        FOREIGN KEY (B1, B2) REFERENCES PNU (U1, U2) ON UPDATE CASCADE);
      COMMIT; INSERT INTO PNU VALUES (1, 10, NULL); COMMIT;
      INSERT INTO CNU VALUES (100, 10, NULL); COMMIT;
      UPDATE PNU SET U1 = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U1, U2 FROM PNU; SELECT X, B1, B2 FROM CNU;"

# ---- 12. HOW DEEP A CASCADE GOES, and it is reached by ROW DATA --------------
# One table with one self-referencing ON DELETE CASCADE reaches the
# ceiling on the (N+1)th GENERATION OF ROWS - no amount of schema review
# warns anyone, so the bound has to be the engine's. Bisected on the
# engine one generation at a time: a chain of 1001 rows cascades away
# whole; 1002 refuses with SQLSTATE 54001 "Too many concurrent
# executions of the same request" and writes NOTHING. Both servers, same
# boundary, same status.
chain() {                  # $1 = table suffix, $2 = rows
    printf 'CREATE TABLE S%s (ID INTEGER NOT NULL PRIMARY KEY, P INTEGER REFERENCES S%s ON DELETE CASCADE);\nCOMMIT;\n' "$1" "$1"
    printf 'INSERT INTO S%s VALUES (1, NULL);\n' "$1"
    i=2; while [ "$i" -le "$2" ]; do
        printf 'INSERT INTO S%s VALUES (%d, %d);\n' "$1" "$i" $((i - 1)); i=$((i + 1))
    done
    printf 'COMMIT;\n'
}
both "a self-referencing cascade 1001 generations deep goes all the way" \
     "$(chain D1 1001) DELETE FROM SD1 WHERE ID = 1; COMMIT; SELECT COUNT(*) N FROM SD1;"
# one generation further both servers refuse. The engine appends its 1000
# `At trigger` frames and this server does not, so what is compared is
# the REFUSAL and the ROWS - the whole of what a user can act on.
both "the chain of 1002 is built identically on both" "$(chain D2 1002) SELECT COUNT(*) N FROM SD2;"
for spec in "$PORT:$A:fire-crab" "$REAL:$B:engine"; do
    pt="${spec%%:*}"; rest="${spec#*:}"; f="${rest%%:*}"; who="${rest#*:}"
    out=$(printf 'SET LIST ON;\nDELETE FROM SD2 WHERE ID = 1; COMMIT;\nSELECT COUNT(*) N FROM SD2;\n' \
          | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$pt:$f" 2>&1 | norm)
    check "one generation further is refused by $who, nothing written" \
          "$(printf '%s' "$out" | cut -d'|' -f1)|$(printf '%s' "$out" | tr '|' '\n' | grep -a '^N ')" \
          "Statement failed, SQLSTATE = 54001|N 1002"
done
eboth "... and the ENGINE reads the same 1002 rows out of each file" \
      "SELECT COUNT(*) N FROM SD2;"
# the depth counter does not leak: the same connection runs a deep
# refusal and then an ordinary cascade
both "a refused deep cascade leaves the counter where it found it" \
     "$(chain D3 20) DELETE FROM SD3 WHERE ID = 1; COMMIT; SELECT COUNT(*) N FROM SD3;"

# ---- 13. WHICH PARTNERSHIP THE MASTER-SIDE CHECK ASKS ------------------------
# THE ENGINE checks ONE dependent foreign key per REFERENCED INDEX - the
# FIRST row of RDB$INDICES, in PHYSICAL RECORD ORDER, whose
# RDB$FOREIGN_KEY names that index - and every partnership behind it on
# the same index goes unchecked, so the parent row is deleted with those
# children still pointing at it. A foreign key on a DIFFERENT index of
# the same parent is a separate question, and the answer is NOT "always
# enforced" - that sentence stood here until 2026-09-03 and a reviewer
# falsified it. The law is ONE CHECK PER REFERENCED INDEX, so a foreign
# key on another index is enforced only if it is THAT index's first.
# Measured on the engine, 2026-09-03, three files, one shape each:
#
#   SP (ID INTEGER PRIMARY KEY, U INTEGER UNIQUE)   -- two indexes
#   KA -> SP(ID)   KB -> SP(U)   KC -> SP(U)        -- FA, FB, FC in that order
#
#   the row sits in KA (the PK index's first FK)     DELETE refused, 23000 "FA"
#   the row sits in KB (the UNIQUE index's first)    DELETE refused, 23000 "FB"
#   the row sits in KC (the UNIQUE index's SECOND)   DELETE PERFORMED:
#                                                    NPARENT 0, KC keeps its
#                                                    row, ORPHAN 1
#
# FC is a foreign key on a DIFFERENT index from FA's and it was not
# enforced, because on its own index it is not the first. fire-crab
# refuses that same DELETE (23000, "FC"), leaves NPARENT 1 and no
# orphan - the same deliberate divergence as the rest of this section.
#
# THIS SERVER CHECKS THEM ALL. That is a deliberate divergence, decided
# after three rounds of chasing the engine's selector shipped three
# silent wrong writes; reproducing it would make foreign-key enforcement
# depend on the engine's physical catalog record PLACEMENT (an ordinary
# DROP TABLE of an unrelated table moves the answer - section 14), and
# what it reproduces is a dangling child row. The decision, its reason
# and its exact consequence are in docs/roadmap.md and on
# fk_check_parent_row in crates/wire/src/server.rs.
#
# So the shapes below split in two. Where BOTH servers refuse, they are
# compared byte for byte as before. Where they diverge, `diverge` asserts
# fire-crab's refusal AND the engine's own answer AND the direction, and
# `noorphan` has the ENGINE read both files back - fire-crab's with no
# dangling child in it, the engine's with the one it left. Nothing here
# stops comparing.
#
# 13a/13b/13c are NOT divergences: they are the wrong write an earlier
# round shipped by ending the walk at the first referenced index, and
# both servers refuse them.

# (a) two referenced keys, an action on one and a restrict child on the
#     other. The wrong write itself.
both "13a two referenced keys: cascade on the PK, restrict child on the UNIQUE" \
     "CREATE TABLE MP2 (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE MA (X INTEGER, B INTEGER REFERENCES MP2 (ID) ON DELETE CASCADE);
      CREATE TABLE MB (X INTEGER, B INTEGER REFERENCES MP2 (U));
      COMMIT; INSERT INTO MP2 VALUES (1, 10); COMMIT;
      INSERT INTO MA VALUES (100, 1); INSERT INTO MB VALUES (200, 10); COMMIT;
      DELETE FROM MP2 WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM MP2; SELECT X, B FROM MA; SELECT X, B FROM MB;"
eboth "... and the ENGINE reads the same rows out of each file, 13a" \
      "SELECT COUNT(*) NP FROM MP2; SELECT X, B FROM MA; SELECT X, B FROM MB;"
both "13b the UPDATE spelling: both keys change, the second index refuses" \
     "CREATE TABLE KP (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE KA (X INTEGER, B INTEGER REFERENCES KP (ID) ON UPDATE CASCADE);
      CREATE TABLE KB (X INTEGER, B INTEGER REFERENCES KP (U));
      COMMIT; INSERT INTO KP VALUES (1, 10); COMMIT;
      INSERT INTO KA VALUES (100, 1); INSERT INTO KB VALUES (200, 10); COMMIT;
      UPDATE KP SET ID = 9, U = 5 WHERE ID = 1; COMMIT;
      SELECT ID, U FROM KP; SELECT X, B FROM KA; SELECT X, B FROM KB;"
eboth "... and the ENGINE reads the same rows out of each file, 13b" \
      "SELECT ID, U FROM KP; SELECT X, B FROM KA; SELECT X, B FROM KB;"
both "13c an ordinary business schema: ORD(ONUM, INVNO), LINES cascade, PAYMENTS restrict" \
     "CREATE TABLE ORD (ID INTEGER NOT NULL PRIMARY KEY, ONUM INTEGER UNIQUE, INVNO INTEGER UNIQUE);
      CREATE TABLE LINES (L INTEGER, ONUM INTEGER REFERENCES ORD (ONUM) ON DELETE CASCADE);
      CREATE TABLE PAYMENTS (P INTEGER, INVNO INTEGER REFERENCES ORD (INVNO));
      COMMIT; INSERT INTO ORD VALUES (1, 5000, 7000); COMMIT;
      INSERT INTO LINES VALUES (1, 5000); INSERT INTO PAYMENTS VALUES (9, 7000); COMMIT;
      DELETE FROM ORD WHERE ID = 1; COMMIT;
      SELECT COUNT(*) N FROM ORD; SELECT L, ONUM FROM LINES; SELECT P, INVNO FROM PAYMENTS;"
eboth "... and the ENGINE reads the same rows out of each file, 13c" \
      "SELECT COUNT(*) N FROM ORD; SELECT L, ONUM FROM LINES; SELECT P, INVNO FROM PAYMENTS;"
both "13d no NULL anywhere: one key cascades, the other merely moves" \
     "CREATE TABLE PX (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER UNIQUE, U2 INTEGER UNIQUE);
      CREATE TABLE CA1 (A INTEGER, B INTEGER REFERENCES PX (U1) ON UPDATE CASCADE);
      CREATE TABLE CB1 (A INTEGER, B INTEGER REFERENCES PX (U2));
      COMMIT; INSERT INTO PX VALUES (1, 10, 20); COMMIT;
      INSERT INTO CA1 VALUES (5, 10); INSERT INTO CB1 VALUES (6, 20); COMMIT;
      UPDATE PX SET U1 = 99, U2 = 21 WHERE ID = 1; COMMIT;
      SELECT U1, U2 FROM PX; SELECT A, B FROM CA1; SELECT A, B FROM CB1;"

# (b) THE SELECTOR, on one index. Each of these rules out a candidate.
# "the first partner whose rule ACTS" would refuse this one; the engine
# performs it, so only partner[0] was ever asked.
diverge "13e partner[0] only, not 'the first that acts': Q1 EMPTY, Q2 holds, Q3 cascades" \
     "CREATE TABLE QP (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE Q1 (X INTEGER, B INTEGER REFERENCES QP);
      CREATE TABLE Q2 (X INTEGER, B INTEGER REFERENCES QP);
      CREATE TABLE Q3 (X INTEGER, B INTEGER REFERENCES QP ON DELETE CASCADE);
      COMMIT; INSERT INTO QP VALUES (1); COMMIT;
      INSERT INTO Q2 VALUES (200, 1); INSERT INTO Q3 VALUES (300, 1); COMMIT;
      DELETE FROM QP WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM QP; SELECT X, B FROM Q2; SELECT COUNT(*) N3 FROM Q3;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_178" on table "PUBLIC"."Q2"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 1)|NP 1|X 200|B 1|N3 1|' \
     'NP 0|X 200|B 1|N3 0|'
noorphan "13e" \
      "SELECT COUNT(*) NP FROM QP; SELECT X, B FROM Q2; SELECT COUNT(*) N3 FROM Q3;" \
      'NP 1|X 200|B 1|N3 1|' \
      'NP 0|X 200|B 1|N3 0|'
# not by CONSTRAINT NAME: FA sorts first and holds the key, FZ is
# declared first and is empty - and the DELETE goes through
diverge "13f not by constraint name: FZ declared first (EMPTY), FA holds the key" \
     "CREATE TABLE QP2 (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE ZA (X INTEGER, B INTEGER, CONSTRAINT FZ FOREIGN KEY (B) REFERENCES QP2);
      CREATE TABLE ZB (X INTEGER, B INTEGER, CONSTRAINT FA FOREIGN KEY (B) REFERENCES QP2);
      CREATE TABLE ZC (X INTEGER, B INTEGER, CONSTRAINT FM FOREIGN KEY (B) REFERENCES QP2 ON DELETE CASCADE);
      COMMIT; INSERT INTO QP2 VALUES (1); COMMIT;
      INSERT INTO ZB VALUES (200, 1); INSERT INTO ZC VALUES (300, 1); COMMIT;
      DELETE FROM QP2 WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM QP2; SELECT X, B FROM ZB; SELECT COUNT(*) NC FROM ZC;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "FA" on table "PUBLIC"."ZB"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 1)|NP 1|X 200|B 1|NC 1|' \
     'NP 0|X 200|B 1|NC 0|'
# not by RELATION ID: R1 has the lowest id and holds the key, but R2's
# constraint was added first
diverge "13g not by relation id: R1 (lowest id) holds, KR2 added first" \
     "CREATE TABLE QP3 (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE R1 (X INTEGER, B INTEGER);
      CREATE TABLE R2 (X INTEGER, B INTEGER);
      CREATE TABLE R3 (X INTEGER, B INTEGER);
      COMMIT;
      ALTER TABLE R2 ADD CONSTRAINT KR2 FOREIGN KEY (B) REFERENCES QP3; COMMIT;
      ALTER TABLE R1 ADD CONSTRAINT KR1 FOREIGN KEY (B) REFERENCES QP3; COMMIT;
      ALTER TABLE R3 ADD CONSTRAINT KR3 FOREIGN KEY (B) REFERENCES QP3 ON DELETE CASCADE; COMMIT;
      INSERT INTO QP3 VALUES (1); COMMIT;
      INSERT INTO R1 VALUES (100, 1); INSERT INTO R3 VALUES (300, 1); COMMIT;
      DELETE FROM QP3 WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM QP3; SELECT X, B FROM R1; SELECT COUNT(*) N3 FROM R3;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "KR1" on table "PUBLIC"."R1"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 1)|NP 1|X 100|B 1|N3 1|' \
     'NP 0|X 100|B 1|N3 0|'
# PER INDEX, not per table: the PK's partnership is empty and clean, and
# says nothing about the UNIQUE's
both "13h per referenced index: MA2 on the PK EMPTY, MB2 on the UNIQUE holds" \
     "CREATE TABLE MP (ID INTEGER NOT NULL PRIMARY KEY, U INTEGER UNIQUE);
      CREATE TABLE MA2 (X INTEGER, B INTEGER, CONSTRAINT KA FOREIGN KEY (B) REFERENCES MP (ID));
      CREATE TABLE MB2 (X INTEGER, B INTEGER, CONSTRAINT KB FOREIGN KEY (B) REFERENCES MP (U));
      COMMIT; INSERT INTO MP VALUES (1, 10); COMMIT;
      INSERT INTO MB2 VALUES (200, 10); COMMIT;
      DELETE FROM MP WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM MP; SELECT X, B FROM MB2;"
# a DEFERRED-DROP leftover is an index row too, and counts
both "13i a deferred-drop leftover ahead of a live FK is the one enforced" \
     "CREATE TABLE DP (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE DC1 (X INTEGER, B INTEGER, CONSTRAINT DK1 FOREIGN KEY (B) REFERENCES DP);
      CREATE TABLE DC2 (X INTEGER, B INTEGER, CONSTRAINT DK2 FOREIGN KEY (B) REFERENCES DP);
      COMMIT; INSERT INTO DP VALUES (1); COMMIT; INSERT INTO DC1 VALUES (100, 1); COMMIT;
      ALTER TABLE DC1 DROP CONSTRAINT DK1; COMMIT;
      DELETE FROM DP WHERE ID = 1; COMMIT;
      SELECT COUNT(*) N FROM DP; SELECT X, B FROM DC1;"

# (c) THE gbak FLIP. The same schema, the same rows and the same
# statement are REFUSED by the engine before a gbak round trip and
# PERFORMED after it, because the restore reverses RDB$INDICES while
# RDB$RELATION_CONSTRAINTS and RDB$REF_CONSTRAINTS keep their order.
#
# A PREVIOUS ROUND CALLED THIS "the shape that decides it, and the only
# one that can". IT IS NOT, AND THAT CLAIM IS WITHDRAWN: a reviewer ran
# gbak -c -v, whose own log prints the order the restore CREATES the
# indexes in - FC, FB, FA, identical to the restored file's physical
# order - so the flip cannot separate physical order from creation
# order. It separates both of them from the two constraint catalogs and
# nothing more. The shape that DOES decide it is section 14's freed
# catalog slot. This one still earns its place: it shows the engine's
# answer following RDB$INDICES while the constraint catalogs stand
# still, and it is where the divergence first bites a restored file.
GBAK="${GBAK:-gbak}"
G1="$D/fc-fkact-g1.fdb"; G2="$D/fc-fkact-g2.fdb"
mk_empty "$G1" && mk_empty "$G2" || { echo "DIFF scratch for 13j"; fail=1; }
oldA="$A"; oldB="$B"; A="$G1"; B="$G2"
both "13j build: FA holds the key, FB and FC empty, all no-rule" \
     "CREATE TABLE QP (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE ZA (X INTEGER, B INTEGER, CONSTRAINT FA FOREIGN KEY (B) REFERENCES QP);
      CREATE TABLE ZB (X INTEGER, B INTEGER, CONSTRAINT FB FOREIGN KEY (B) REFERENCES QP);
      CREATE TABLE ZC (X INTEGER, B INTEGER, CONSTRAINT FC FOREIGN KEY (B) REFERENCES QP);
      COMMIT; INSERT INTO QP VALUES (1); COMMIT; INSERT INTO ZA VALUES (100, 1); COMMIT;
      SELECT RDB\$INDEX_NAME FROM RDB\$INDICES WHERE RDB\$FOREIGN_KEY IS NOT NULL;"
both "13j as created (physical order FA, FB, FC) the DELETE is REFUSED naming FA" \
     "DELETE FROM QP WHERE ID = 1; COMMIT; SELECT COUNT(*) NP FROM QP; SELECT X, B FROM ZA;"
for f in "$G1" "$G2"; do
    "$GBAK" -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$f" "$f.fbk" >/dev/null 2>&1
    rm -f "$f.r"
    "$GBAK" -c -user "$U" -pas "$P" "$f.fbk" "127.0.0.1/$REAL:$f.r" >/dev/null 2>&1
    chmod 666 "$f.r" 2>/dev/null
done
A="$G1.r"; B="$G2.r"
both "13k the restore REVERSES RDB\$INDICES to FC, FB, FA" \
     "SELECT RDB\$INDEX_NAME FROM RDB\$INDICES WHERE RDB\$FOREIGN_KEY IS NOT NULL;"
both "13k ...while RDB\$RELATION_CONSTRAINTS keeps its order FA, FB, FC" \
     "SELECT RDB\$CONSTRAINT_NAME FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$CONSTRAINT_TYPE = 'FOREIGN KEY';"
diverge "13k the SAME DELETE now SUCCEEDS on the ENGINE, leaving FA's child dangling" \
     "DELETE FROM QP WHERE ID = 1; COMMIT; SELECT COUNT(*) NP FROM QP; SELECT X, B FROM ZA;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "FA" on table "PUBLIC"."ZA"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 1)|NP 1|X 100|B 1|' \
     'NP 0|X 100|B 1|'
noorphan "13k the restored file" \
      "SELECT COUNT(*) NP FROM QP; SELECT X, B FROM ZA;" \
      'NP 1|X 100|B 1|' \
      'NP 0|X 100|B 1|'
rm -f "$G1" "$G2" "$G1.fbk" "$G2.fbk" "$G1.r" "$G2.r"
A="$oldA"; B="$oldB"

# (d) EIGHT CHILDREN, ONE PARENT INDEX, one under each rule - the matrix
# that shows the selection is not about the RULE at all. Every parent row
# is referenced by exactly ONE child, so what happens to each says which
# partnership was asked.
both "13l eight children under eight rules, one referencing child per parent row" \
     "CREATE TABLE PZ (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE ZRE (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ);
      CREATE TABLE ZDC (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ ON DELETE CASCADE);
      CREATE TABLE ZDN (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ ON DELETE SET NULL);
      CREATE TABLE ZDD (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ ON DELETE SET DEFAULT);
      CREATE TABLE ZUC (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ ON UPDATE CASCADE);
      CREATE TABLE ZUN (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ ON UPDATE SET NULL);
      CREATE TABLE ZUD (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ ON UPDATE SET DEFAULT);
      CREATE TABLE ZNA (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ);
      COMMIT;
      INSERT INTO PZ VALUES (1); INSERT INTO PZ VALUES (2); INSERT INTO PZ VALUES (3);
      INSERT INTO PZ VALUES (4); INSERT INTO PZ VALUES (5); INSERT INTO PZ VALUES (6);
      INSERT INTO PZ VALUES (7); INSERT INTO PZ VALUES (8); COMMIT;
      INSERT INTO ZRE VALUES (10, 1); INSERT INTO ZDC VALUES (20, 2);
      INSERT INTO ZDN VALUES (30, 3); INSERT INTO ZDD VALUES (40, 4);
      INSERT INTO ZUC VALUES (50, 5); INSERT INTO ZUN VALUES (60, 6);
      INSERT INTO ZUD VALUES (70, 7); INSERT INTO ZNA VALUES (80, 8); COMMIT;
      SELECT RDB\$RELATION_NAME FROM RDB\$INDICES WHERE RDB\$FOREIGN_KEY IS NOT NULL
        AND RDB\$RELATION_NAME IN ('ZRE','ZDC','ZDN','ZDD','ZUC','ZUN','ZUD','ZNA');"
# Parents 1-4 AGREE: ZRE is the physically first partnership and holds
# key 1, so both servers refuse 1; keys 2, 3 and 4 are held only by an
# ACTING partnership whose action clears them, so both servers perform
# those. Parents 5-8 are held by a partnership the engine never asks -
# ZUC, ZUN and ZUD declare only ON UPDATE rules (so they RESTRICT a
# DELETE) and ZNA declares none at all. The engine asks ZRE, which is
# empty for those keys, and deletes the parent under them. Note key 7:
# ZDD's ON DELETE SET DEFAULT wrote 7 when parent 4 went, so by then TWO
# partnerships hold 7 and the engine still asks neither.
for i in 1 2 3 4; do
    both "13l DELETE parent $i" \
         "DELETE FROM PZ WHERE ID = $i; COMMIT; SELECT COUNT(*) N FROM PZ;"
done
diverge "13l DELETE parent 5 (held only by ZUC, ON UPDATE CASCADE)" \
    "DELETE FROM PZ WHERE ID = 5; COMMIT; SELECT COUNT(*) N FROM PZ;" \
    'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_195" on table "PUBLIC"."ZUC"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 5)|N 5|' \
    'N 4|'
diverge "13l DELETE parent 6 (held only by ZUN, ON UPDATE SET NULL)" \
    "DELETE FROM PZ WHERE ID = 6; COMMIT; SELECT COUNT(*) N FROM PZ;" \
    'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_196" on table "PUBLIC"."ZUN"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 6)|N 5|' \
    'N 3|'
diverge "13l DELETE parent 7 (held by ZUD and by what ZDD's SET DEFAULT wrote)" \
    "DELETE FROM PZ WHERE ID = 7; COMMIT; SELECT COUNT(*) N FROM PZ;" \
    'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_194" on table "PUBLIC"."ZDD"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 7)|N 5|' \
    'N 2|'
diverge "13l DELETE parent 8 (held only by ZNA, no rule at all)" \
    "DELETE FROM PZ WHERE ID = 8; COMMIT; SELECT COUNT(*) N FROM PZ;" \
    'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_198" on table "PUBLIC"."ZNA"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 8)|N 5|' \
    'N 1|'
noorphan "13l the eight-child matrix" \
      "SELECT COUNT(*) N FROM PZ;
       SELECT X, B FROM ZRE; SELECT X, B FROM ZDC; SELECT X, B FROM ZDN; SELECT X, B FROM ZDD;
       SELECT X, B FROM ZUC; SELECT X, B FROM ZUN; SELECT X, B FROM ZUD; SELECT X, B FROM ZNA;" \
      'N 5|X 10|B 1|X 30|B <null>|X 40|B 7|X 50|B 5|X 60|B 6|X 70|B 7|X 80|B 8|' \
      'N 1|X 10|B 1|X 30|B <null>|X 40|B 7|X 50|B 5|X 60|B 6|X 70|B 7|X 80|B 8|'

# (e) THE CHECK SEES WHAT THE ACTION LEAVES BEHIND. An acting
# partnership is not SKIPPED: the engine's action is an AFTER trigger and
# the master-side check reads the child once it has run. `SET DEFAULT` is
# the one rule that can write the key straight back, and there the engine
# REFUSES - "skip an acting partner" would have deleted the parent.
both "13m ON DELETE SET DEFAULT whose default IS the key going away: refused" \
     "CREATE TABLE SP (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE SC (X INTEGER, B INTEGER DEFAULT 7, CONSTRAINT SK FOREIGN KEY (B) REFERENCES SP ON DELETE SET DEFAULT);
      COMMIT; INSERT INTO SP VALUES (7); COMMIT; INSERT INTO SC VALUES (100, 7); COMMIT;
      DELETE FROM SP WHERE ID = 7; COMMIT;
      SELECT COUNT(*) N FROM SP; SELECT X, B FROM SC;"
eboth "... and the ENGINE reads the same rows out of each file, 13m" \
      "SELECT COUNT(*) N FROM SP; SELECT X, B FROM SC;"
both "13n the ON UPDATE SET DEFAULT spelling of the same" \
     "CREATE TABLE SP1 (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE SC1 (X INTEGER, B INTEGER DEFAULT 7, CONSTRAINT SK1 FOREIGN KEY (B) REFERENCES SP1 ON UPDATE SET DEFAULT);
      COMMIT; INSERT INTO SP1 VALUES (7); COMMIT; INSERT INTO SC1 VALUES (100, 7); COMMIT;
      UPDATE SP1 SET ID = 8 WHERE ID = 7; COMMIT;
      SELECT ID FROM SP1; SELECT X, B FROM SC1;"
both "13o ...and a default that is a DIFFERENT key clears it, so the DELETE goes" \
     "CREATE TABLE SP2 (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE SC2 (X INTEGER, B INTEGER DEFAULT 3, CONSTRAINT SK2 FOREIGN KEY (B) REFERENCES SP2 ON DELETE SET DEFAULT);
      COMMIT; INSERT INTO SP2 VALUES (3); INSERT INTO SP2 VALUES (7); COMMIT;
      INSERT INTO SC2 VALUES (100, 7); COMMIT;
      DELETE FROM SP2 WHERE ID = 7; COMMIT;
      SELECT ID FROM SP2 ORDER BY ID; SELECT X, B FROM SC2;"
# ...and the CHILD side of the same law: an UPDATE that leaves the key
# equal is not checked at all, which is why the engine's action writes 7
# over 7 without the CHILD side saying anything. The engine then deletes
# the parent, because the partnership its MASTER side asks is Z0, which
# is empty; this server asks ZD2 as well and refuses. The contrast (13q,
# DEFAULT 77) really moves the key and is refused child-side by BOTH.
diverge "13p an action that rewrites the key unchanged is not child-checked" \
     "CREATE TABLE PZ2 (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE Z0 (X INTEGER, B INTEGER REFERENCES PZ2);
      CREATE TABLE ZD2 (X INTEGER, B INTEGER DEFAULT 7 REFERENCES PZ2 ON DELETE SET DEFAULT);
      COMMIT; INSERT INTO PZ2 VALUES (7); COMMIT; INSERT INTO ZD2 VALUES (30, 7); COMMIT;
      DELETE FROM PZ2 WHERE ID = 7; COMMIT;
      SELECT COUNT(*) N FROM PZ2; SELECT X, B FROM ZD2;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_208" on table "PUBLIC"."ZD2"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 7)|N 1|X 30|B 7|' \
     'N 0|X 30|B 7|'
noorphan "13p" \
     "SELECT COUNT(*) N FROM PZ2; SELECT X, B FROM ZD2;" \
     'N 1|X 30|B 7|' \
     'N 0|X 30|B 7|'
both "13q ...and one that really moves it to a parentless value IS refused" \
     "CREATE TABLE PY2 (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE Y0 (X INTEGER, B INTEGER REFERENCES PY2);
      CREATE TABLE YD2 (X INTEGER, B INTEGER DEFAULT 77 REFERENCES PY2 ON DELETE SET DEFAULT);
      COMMIT; INSERT INTO PY2 VALUES (7); COMMIT; INSERT INTO YD2 VALUES (30, 7); COMMIT;
      DELETE FROM PY2 WHERE ID = 7; COMMIT;
      SELECT COUNT(*) N FROM PY2; SELECT X, B FROM YD2;"

# (f) "DID THE KEY CHANGE" IS `IS DISTINCT FROM`: two NULLs are ONE key.
# Rewriting a partly-NULL key with its own values changes nothing and
# must not refuse - and the refusal cost the row's OTHER columns too.
both "13r a partly-NULL key rewritten with its own values, no rule" \
     "CREATE TABLE PE1 (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, UNIQUE (U1, U2));
      CREATE TABLE CE1 (X INTEGER, B1 INTEGER, B2 INTEGER, FOREIGN KEY (B1, B2) REFERENCES PE1 (U1, U2));
      COMMIT; INSERT INTO PE1 VALUES (1, 10, NULL); COMMIT;
      INSERT INTO CE1 VALUES (100, 10, NULL); COMMIT;
      UPDATE PE1 SET U1 = 10, U2 = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U1, U2 FROM PE1; SELECT X, B1, B2 FROM CE1;"
both "13s ...the same under ON UPDATE CASCADE" \
     "CREATE TABLE PE2 (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, UNIQUE (U1, U2));
      CREATE TABLE CE2 (X INTEGER, B1 INTEGER, B2 INTEGER, FOREIGN KEY (B1, B2) REFERENCES PE2 (U1, U2) ON UPDATE CASCADE);
      COMMIT; INSERT INTO PE2 VALUES (1, 10, NULL); COMMIT;
      INSERT INTO CE2 VALUES (100, 10, NULL); COMMIT;
      UPDATE PE2 SET U1 = 10, U2 = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U1, U2 FROM PE2; SELECT X, B1, B2 FROM CE2;"
both "13t the whole-row ORM UPDATE: the columns that DO change are written" \
     "CREATE TABLE PE3 (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, X INTEGER, UNIQUE (U1, U2));
      CREATE TABLE CE3 (A INTEGER, B1 INTEGER, B2 INTEGER, FOREIGN KEY (B1, B2) REFERENCES PE3 (U1, U2));
      COMMIT; INSERT INTO PE3 VALUES (1, 10, NULL, 100); COMMIT;
      INSERT INTO CE3 VALUES (5, 10, NULL); COMMIT;
      UPDATE PE3 SET U1 = 10, U2 = NULL, X = 1 WHERE ID = 1; COMMIT;
      SELECT ID, U1, U2, X FROM PE3; SELECT A, B1, B2 FROM CE3;"
eboth "... and the ENGINE reads the same rows out of each file, 13t" \
      "SELECT ID, U1, U2, X FROM PE3; SELECT A, B1, B2 FROM CE3;"
both "13u ...and a change that really MOVES a partly-NULL key is still refused" \
     "CREATE TABLE PE4 (ID INTEGER NOT NULL PRIMARY KEY, U1 INTEGER, U2 INTEGER, UNIQUE (U1, U2));
      CREATE TABLE CE4 (X INTEGER, B1 INTEGER, B2 INTEGER, FOREIGN KEY (B1, B2) REFERENCES PE4 (U1, U2));
      COMMIT; INSERT INTO PE4 VALUES (1, 10, NULL); COMMIT;
      INSERT INTO CE4 VALUES (100, 10, NULL); COMMIT;
      UPDATE PE4 SET U1 = NULL, U2 = NULL WHERE ID = 1; COMMIT;
      SELECT ID, U1, U2 FROM PE4; SELECT X, B1, B2 FROM CE4;"

# ---- 14. THE DIVERGENCE, ON THE SHAPES THAT DECIDED IT -----------------------
# Four shapes: the measurement quoted in the decision, the freed catalog
# slot that actually proves the engine's selector, and the two silent
# wrong writes the last round shipped by reproducing it.

# (a) the measurement quoted in docs/roadmap.md and on
# fk_check_parent_row: two children, the physically first one EMPTY.
diverge "14a QP/Q1/Q2: the engine deletes a parent V2 still references" \
     "CREATE TABLE VP (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE V1 (X INTEGER, B INTEGER REFERENCES VP);
      CREATE TABLE V2 (X INTEGER, B INTEGER REFERENCES VP);
      COMMIT; INSERT INTO VP VALUES (1); COMMIT; INSERT INTO V2 VALUES (200, 1); COMMIT;
      DELETE FROM VP WHERE ID = 1; COMMIT;
      SELECT COUNT(*) NP FROM VP; SELECT X, B FROM V2;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "INTEG_232" on table "PUBLIC"."V2"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 1)|NP 1|X 200|B 1|' \
     'NP 0|X 200|B 1|'
noorphan "14a QP/Q1/Q2" \
     "SELECT COUNT(*) NP FROM VP; SELECT X, B FROM V2;" \
     'NP 1|X 200|B 1|' \
     'NP 0|X 200|B 1|'

# (b) THE SHAPE THAT DECIDES THE ENGINE'S SELECTOR, and why fire-crab
# does not reproduce it. Nothing here but an ordinary DROP TABLE of an
# UNRELATED table: it frees an RDB$INDICES slot, the engine puts the
# NEXT index into it, and this server appends. FB is created BEFORE FA,
# and in the engine's file FA's row lands PHYSICALLY FIRST - creation
# order says ask FB, physical order says ask FA, and the engine asks FA.
# That is what makes the selector unreproducible without matching the
# engine's catalog record PLACEMENT, and it is the first reason for the
# decision. (The gbak flip in 13j/13k cannot decide this: gbak -c -v
# shows the restore CREATES the indexes in the restored file's physical
# order, so the two move together there.)
H1="$D/fc-fkact-h1.fdb"; H2="$D/fc-fkact-h2.fdb"
mk_empty "$H1" && mk_empty "$H2" || { echo "DIFF scratch for 14b"; fail=1; }
oldA="$A"; oldB="$B"; A="$H1"; B="$H2"
both "14b build: JUNK dropped between FB and FA, RA holds key 1, RB holds key 2" \
     "CREATE TABLE RP (ID INTEGER NOT NULL PRIMARY KEY);
      CREATE TABLE JUNK (A INTEGER); CREATE INDEX J1 ON JUNK (A); COMMIT;
      CREATE TABLE RB (X INTEGER, B INTEGER, CONSTRAINT FB FOREIGN KEY (B) REFERENCES RP); COMMIT;
      DROP TABLE JUNK; COMMIT;
      CREATE TABLE RA (X INTEGER, B INTEGER, CONSTRAINT FA FOREIGN KEY (B) REFERENCES RP); COMMIT;
      INSERT INTO RP VALUES (1); INSERT INTO RP VALUES (2); COMMIT;
      INSERT INTO RA VALUES (100, 1); INSERT INTO RB VALUES (200, 2); COMMIT;
      SELECT COUNT(*) NP FROM RP; SELECT COUNT(*) NA FROM RA; SELECT COUNT(*) NB FROM RB;"
efiles "14b the freed slot: RDB\$INDICES in physical record order" \
     "SELECT TRIM(RDB\$INDEX_NAME) || ' ' || TRIM(RDB\$RELATION_NAME) IX FROM RDB\$INDICES
        WHERE COALESCE(RDB\$SYSTEM_FLAG, 0) = 0 ORDER BY RDB\$DB_KEY;" \
     'IX RDB$PRIMARY1 RP|IX FB RB|IX FA RA|' \
     'IX RDB$PRIMARY1 RP|IX FA RA|IX FB RB|'
both "14b RA (physically first on the ENGINE) holds key 1: BOTH refuse, naming FA" \
     "DELETE FROM RP WHERE ID = 1; COMMIT; SELECT COUNT(*) NP FROM RP; SELECT X, B FROM RA;"
diverge "14c RB (physically SECOND on the engine) holds key 2: only fire-crab refuses" \
     "DELETE FROM RP WHERE ID = 2; COMMIT; SELECT COUNT(*) NP FROM RP; SELECT X, B FROM RB;" \
     'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "FB" on table "PUBLIC"."RB"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 2)|NP 2|X 200|B 2|' \
     'NP 1|X 200|B 2|'
noorphan "14c the freed-slot shape" \
     "SELECT COUNT(*) NP FROM RP; SELECT X, B FROM RA; SELECT X, B FROM RB;" \
     'NP 2|X 100|B 1|X 200|B 2|' \
     'NP 1|X 100|B 1|X 200|B 2|'
rm -f "$H1" "$H2"
A="$oldA"; B="$oldB"

# (d) THE TWO SILENT WRONG WRITES the previous round shipped, and they
# are PARITY checks now, not divergences - both servers refuse both.
#
# (d1) SET DEFAULT whose default is not a literal. The action writes
# CURRENT_USER, which IS the key going away, so the check must still
# refuse - "an action is a WRITE, not a waiver" holds for every default
# the server can evaluate, not only for literals.
both "14d ON DELETE SET DEFAULT with DEFAULT CURRENT_USER" \
     "CREATE TABLE SPU (ID VARCHAR(31) NOT NULL PRIMARY KEY); COMMIT;
      CREATE TABLE SCU (X INTEGER, B VARCHAR(31) DEFAULT CURRENT_USER,
        CONSTRAINT SKU FOREIGN KEY (B) REFERENCES SPU ON DELETE SET DEFAULT); COMMIT;
      INSERT INTO SPU VALUES ('SYSDBA'); INSERT INTO SCU VALUES (100, 'SYSDBA'); COMMIT;
      DELETE FROM SPU WHERE ID = 'SYSDBA'; COMMIT;
      SELECT COUNT(*) NP FROM SPU; SELECT X, B FROM SCU;"
both "14d the ON UPDATE spelling of the same" \
     "CREATE TABLE SPV (ID VARCHAR(31) NOT NULL PRIMARY KEY); COMMIT;
      CREATE TABLE SCV (X INTEGER, B VARCHAR(31) DEFAULT CURRENT_USER,
        CONSTRAINT SKV FOREIGN KEY (B) REFERENCES SPV ON UPDATE SET DEFAULT); COMMIT;
      INSERT INTO SPV VALUES ('SYSDBA'); INSERT INTO SCV VALUES (100, 'SYSDBA'); COMMIT;
      UPDATE SPV SET ID = 'OTHER' WHERE ID = 'SYSDBA'; COMMIT;
      SELECT ID FROM SPV; SELECT X, B FROM SCV;"
both "14d ...and a non-literal default that is a DIFFERENT key clears it" \
     "CREATE TABLE SPW (ID VARCHAR(31) NOT NULL PRIMARY KEY); COMMIT;
      CREATE TABLE SCW (X INTEGER, B VARCHAR(31) DEFAULT CURRENT_ROLE,
        CONSTRAINT SKW FOREIGN KEY (B) REFERENCES SPW ON DELETE SET DEFAULT); COMMIT;
      INSERT INTO SPW VALUES ('NONE'); INSERT INTO SPW VALUES ('SYSDBA');
      INSERT INTO SCW VALUES (100, 'SYSDBA'); COMMIT;
      DELETE FROM SPW WHERE ID = 'SYSDBA'; COMMIT;
      SELECT ID FROM SPW ORDER BY ID; SELECT X, B FROM SCW;"
eboth "... and the ENGINE reads the same rows out of each file, 14d" \
      "SELECT COUNT(*) NP FROM SPU; SELECT X, B FROM SCU;
       SELECT ID FROM SPV; SELECT X, B FROM SCV;
       SELECT ID FROM SPW ORDER BY ID; SELECT X, B FROM SCW;"

# (d2) DROP CONSTRAINT and re-ADD. The two files' RDB$INDICES layouts
# part company here - this server places the re-added row before HFB and
# leaves the deferred-drop leftover's RDB$FOREIGN_KEY set, the engine
# appends and clears it - and under the old one-row-per-index selector
# that difference decided whether the key was enforced at all. Under the
# decision it decides nothing: every partnership is asked either way.
both "14e DROP CONSTRAINT + re-ADD: build, HA empty, HB holds the key" \
     "CREATE TABLE HP (ID INTEGER NOT NULL PRIMARY KEY); COMMIT;
      CREATE TABLE HA (X INTEGER, B INTEGER, CONSTRAINT HFA FOREIGN KEY (B) REFERENCES HP);
      CREATE TABLE HB (X INTEGER, B INTEGER, CONSTRAINT HFB FOREIGN KEY (B) REFERENCES HP); COMMIT;
      INSERT INTO HP VALUES (1); INSERT INTO HB VALUES (100, 1); COMMIT;
      ALTER TABLE HA DROP CONSTRAINT HFA; COMMIT;
      ALTER TABLE HA ADD CONSTRAINT HFA FOREIGN KEY (B) REFERENCES HP; COMMIT;
      SELECT COUNT(*) N FROM HB;"
# The child side only: the parent's own PRIMARY index carries a
# generated name whose COUNTER the two servers already disagree on (a
# separate, disclosed gap), and this check is about placement and about
# the leftover's RDB$FOREIGN_KEY, not about that. `fk=` READS the column
# - it used to print COALESCE('set','-') over a row set already filtered
# to IS NOT NULL, which is a constant dressed as a measurement and hid
# the very difference this check exists for: the ENGINE clears the
# deferred-drop leftover's RDB$FOREIGN_KEY (fk=null) and this server
# leaves it set. The leftover's name carries a transaction counter, so
# the name is normalised and the ORDER, the RELATION and the fk STATE
# are what is pinned.
efiles "14e the two layouts after the re-ADD (a DISCLOSED difference)" \
     "SELECT CASE WHEN RDB\$INDEX_NAME STARTING WITH 'RDB\$TEMP_DEPEND'
                  THEN 'RDB\$TEMP_DEPEND_*' ELSE TRIM(RDB\$INDEX_NAME) END
             || ' rel=' || TRIM(RDB\$RELATION_NAME) || ' fk=' ||
             CASE WHEN RDB\$FOREIGN_KEY IS NULL THEN 'null' ELSE 'set' END IX
        FROM RDB\$INDICES WHERE RDB\$RELATION_NAME IN ('HA', 'HB')
        ORDER BY RDB\$DB_KEY;" \
     'IX RDB$TEMP_DEPEND_* rel=HA fk=set|IX HFB rel=HB fk=set|IX HFA rel=HA fk=set|' \
     'IX RDB$TEMP_DEPEND_* rel=HA fk=null|IX HFB rel=HB fk=set|IX HFA rel=HA fk=set|'
both "14e ...and the DELETE is refused by BOTH, naming HFB" \
     "DELETE FROM HP WHERE ID = 1; COMMIT; SELECT COUNT(*) NP FROM HP; SELECT X, B FROM HB;"
eboth "... and the ENGINE reads the same rows out of each file, 14e" \
      "SELECT COUNT(*) NP FROM HP; SELECT X, B FROM HB;"

# ---- 16. A MIXED EXACT-NUMERIC PAIR IS ONE KEY --------------------------------
# Firebird accepts a foreign key whose child column differs from the
# parent key in SCALE, and a SET DEFAULT literal is written at the
# literal's own scale. Both put an `Int` (scale 0) beside a `Scaled` or
# an `Int128` in `value_cmp`, which had NO arm for such a pair until
# 2026-09-03 and fell to a rendered-text comparison, where "7" and
# "7.00" are different strings. That cost a whole foreign key: an
# ORPHAN on the parent side and a REFUSAL on the child side of one
# schema.
#
# HOW MUCH OF THIS SECTION IS EVIDENCE OF THAT, measured rather than
# asserted. A sentence here used to read "Every check below was a DIFF
# before that arm existed"; a reviewer disproved it by building the
# binary, and it is measured again on 2026-09-03 against a binary built
# from this tree with `value_cmp`'s mixed-kind arm narrowed back to the
# three same-kind pairs (so a mixed pair falls to the rendered-text tail,
# as it did before the arm): the gate reads rc=1, 189 OK / 20 DIFF, and
# ALL 20 DIFFs are in this section. Section 16 is 37 checks, so
# SEVENTEEN of them did not move, and were never going to:
#
#   16a  6 DIFF / 10   16b  6 DIFF / 10   16c  2 DIFF / 3
#   16d  3 DIFF / 3    16e  3 DIFF / 3    16f  0 DIFF / 4
#   16g  0 DIFF / 4
#
# The seventeen are: the three `build` checks that raise each width's
# schema, 16c's build, all four `16b/N20` checks (parent NUMERIC(20,2)
# against an INT128 child - an `Int128` beside an `Int128` is a
# SAME-KIND pair and always had an arm), one `16a/N20` refusal, 16f's
# four CONTRASTS, which exist to stay put and whose own comment forty
# lines below says so, and 16g's four decimal-default DDL checks, which
# the arm does not touch.
#
# The child column's WIDTH still has to match the parent key's - the
# engine refuses `NUMERIC(18,2)` against `INTEGER` with "partner index
# segment no 1 has incompatible data type" - so each width pairs with
# its own scale-0 type: INTEGER, BIGINT, INT128.
for spec in "N9:NUMERIC(9,2):INTEGER" "N18:NUMERIC(18,2):BIGINT" "N20:NUMERIC(20,2):INT128"; do
    n="${spec%%:*}"; rest="${spec#*:}"; t="${rest%%:*}"; z="${rest#*:}"
    # (a) PARENT SIDE - `DEFAULT 7` writes the key 7.00 straight back,
    # so the DELETE must be REFUSED. It was performed, and the ENGINE
    # then read a dangling child row out of THIS server's file.
    both "16a/$n $t key, child DEFAULT 7 ON DELETE SET DEFAULT: build" \
         "CREATE TABLE MP$n (ID $t NOT NULL PRIMARY KEY);
          CREATE TABLE MC$n (X INTEGER, B $t DEFAULT 7,
                             CONSTRAINT MK$n FOREIGN KEY (B) REFERENCES MP$n ON DELETE SET DEFAULT);
          COMMIT;
          INSERT INTO MP$n VALUES (7.00); INSERT INTO MC$n VALUES (100, 7.00); COMMIT;
          SELECT ID PID FROM MP$n; SELECT B CB FROM MC$n;"
    dsql="DELETE FROM MP$n WHERE ID = 7.00; COMMIT;
          SELECT COUNT(*) NP FROM MP$n; SELECT B CB FROM MC$n;"
    if [ "$n" = "N20" ]; then
        # an INT128-backed key loses the `-Problematic key value` line
        # in this server's refusal - PRE-EXISTING (byte-identical on the
        # previous round's binary for a plain no-rule child, and for
        # NUMERIC(19,2) and INT128 alike), recorded in docs/roadmap.md.
        # Both answers are pinned rather than skipped.
        gap "16a/$n DELETE the key the default writes back - both REFUSE" "$dsql" \
            'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "MKN20" on table "PUBLIC"."MCN20"|-Foreign key references are present for the record|NP 1|CB 7.00|' \
            'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "MKN20" on table "PUBLIC"."MCN20"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 7.00)|NP 1|CB 7.00|'
    else
        both "16a/$n DELETE the key the default writes back - both REFUSE" "$dsql"
    fi
    eboth "16a/$n the ENGINE reads both files: the parent kept, NO orphan" \
          "SELECT COUNT(*) NPAR FROM MP$n;
           SELECT COUNT(*) ORPH FROM MC$n c WHERE c.B IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM MP$n p WHERE p.ID = c.B);"
    # (b) CHILD SIDE - the parent key scaled, the child column at scale
    # 0. The INSERT is VALID and was refused ("Foreign key reference
    # target does not exist"), and the parent DELETE then went through
    # because the child had never landed.
    both "16b/$n cross-scale FK (parent $t, child $z): a VALID child INSERT" \
         "CREATE TABLE XP$n (ID $t NOT NULL PRIMARY KEY);
          CREATE TABLE XC$n (X INTEGER, B $z, CONSTRAINT XK$n FOREIGN KEY (B) REFERENCES XP$n);
          COMMIT; INSERT INTO XP$n VALUES (7.00); COMMIT;
          INSERT INTO XC$n VALUES (1, 7); COMMIT; SELECT COUNT(*) NXC FROM XC$n;"
    xsql="DELETE FROM XP$n WHERE ID = 7.00; COMMIT; SELECT COUNT(*) NXP FROM XP$n;"
    if [ "$n" = "N20" ]; then
        # the same PRE-EXISTING INT128 message gap as 16a/N20
        gap "16b/$n ...and the parent DELETE is then REFUSED by both" "$xsql" \
            'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "XKN20" on table "PUBLIC"."XCN20"|-Foreign key references are present for the record|NXP 1|' \
            'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "XKN20" on table "PUBLIC"."XCN20"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 7.00)|NXP 1|'
    else
        both "16b/$n ...and the parent DELETE is then REFUSED by both" "$xsql"
    fi
    eboth "16b/$n the ENGINE reads both files: the parent kept, NO orphan" \
          "SELECT COUNT(*) NXP FROM XP$n; SELECT COUNT(*) NXC FROM XC$n;
           SELECT COUNT(*) ORPH FROM XC$n c WHERE c.B IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM XP$n p WHERE p.ID = c.B);"
done
# (c) the ON UPDATE spelling of (a): SET DEFAULT rewrites the OLD key
both "16c ON UPDATE SET DEFAULT at scale 0 against a NUMERIC(9,2) key: build" \
     "CREATE TABLE MUP (ID NUMERIC(9,2) NOT NULL PRIMARY KEY);
      CREATE TABLE MUC (X INTEGER, B NUMERIC(9,2) DEFAULT 7 REFERENCES MUP ON UPDATE SET DEFAULT);
      COMMIT; INSERT INTO MUP VALUES (7.00); INSERT INTO MUC VALUES (100, 7.00); COMMIT;
      SELECT ID PID FROM MUP;"
both "16c UPDATE MUP SET ID = 8.00 - REFUSED by both" \
     "UPDATE MUP SET ID = 8.00 WHERE ID = 7.00; COMMIT;
      SELECT ID PID FROM MUP; SELECT B CB FROM MUC;"
eboth "16c the ENGINE reads both files: the key unmoved, NO orphan" \
      "SELECT ID PID FROM MUP; SELECT B CB FROM MUC;
       SELECT COUNT(*) ORPH FROM MUC c WHERE c.B IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM MUP p WHERE p.ID = c.B);"
# (d) the mirror of (b): the parent key at scale 0, the child scaled.
# This is the orders/lines shape a reviewer built entirely on the ENGINE
# - an ordinary NO ACTION foreign key, no referential action anywhere -
# and this server deleted the order out from under its live line.
both "16d ODR/OLN, parent INTEGER key, child NUMERIC(9,2), no rule at all" \
     "CREATE TABLE ODR (ID INTEGER NOT NULL PRIMARY KEY, NOTE VARCHAR(20));
      CREATE TABLE OLN (LID INTEGER NOT NULL PRIMARY KEY, ORDID NUMERIC(9,2), QTY INTEGER,
                        CONSTRAINT LFK FOREIGN KEY (ORDID) REFERENCES ODR);
      COMMIT; INSERT INTO ODR VALUES (1,'a'); INSERT INTO OLN VALUES (10, 1, 5); COMMIT;
      SELECT COUNT(*) NORD FROM ODR; SELECT COUNT(*) NL FROM OLN;"
both "16d DELETE FROM ODR WHERE ID = 1 - REFUSED by both, naming LFK" \
     "DELETE FROM ODR WHERE ID = 1; COMMIT; SELECT COUNT(*) NORD FROM ODR;"
eboth "16d the ENGINE reads both files: the order kept, NO orphan line" \
      "SELECT COUNT(*) NORD FROM ODR;
       SELECT COUNT(*) OL FROM OLN l WHERE l.ORDID IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM ODR o WHERE o.ID = l.ORDID);"
# (e) a COMPOUND key crossing scales on one segment
both "16e compound key, one segment scaled: a VALID child INSERT" \
     "CREATE TABLE ZCP (U1 INTEGER NOT NULL, U2 NUMERIC(9,2) NOT NULL,
                        CONSTRAINT ZCPK PRIMARY KEY (U1, U2));
      CREATE TABLE ZCC (X INTEGER, B1 NUMERIC(9,2), B2 INTEGER,
                        CONSTRAINT ZCCK FOREIGN KEY (B1, B2) REFERENCES ZCP (U1, U2));
      COMMIT; INSERT INTO ZCP VALUES (10, 20.00); COMMIT;
      INSERT INTO ZCC VALUES (1, 10, 20); COMMIT; SELECT COUNT(*) NCC FROM ZCC;"
both "16e ...and the compound parent DELETE is REFUSED by both" \
     "DELETE FROM ZCP WHERE U1 = 10; COMMIT; SELECT COUNT(*) NCP FROM ZCP;"
eboth "16e the ENGINE reads both files: the parent kept, NO orphan" \
      "SELECT COUNT(*) NCP FROM ZCP; SELECT COUNT(*) NCC FROM ZCC;
       SELECT COUNT(*) ORPH FROM ZCC c WHERE c.B1 IS NOT NULL AND NOT EXISTS
         (SELECT 1 FROM ZCP p WHERE p.U1 = c.B1 AND p.U2 = c.B2);"
# (f) CONTRASTS that must NOT move. The pair is only mixed when one side
# is scale 0: two SCALED sides always had an arm, and the approximate
# keys never reach the exact alignment at all.
both "16f contrast NUMERIC(9,1) parent / NUMERIC(9,3) child - both sides scaled" \
     "CREATE TABLE ZS1 (ID NUMERIC(9,1) NOT NULL PRIMARY KEY);
      CREATE TABLE ZC1 (X INTEGER, B NUMERIC(9,3), CONSTRAINT ZSK1 FOREIGN KEY (B) REFERENCES ZS1);
      COMMIT; INSERT INTO ZS1 VALUES (7.0); COMMIT; INSERT INTO ZC1 VALUES (1, 7.000); COMMIT;
      DELETE FROM ZS1 WHERE ID = 7.0; COMMIT; SELECT COUNT(*) N FROM ZS1;"
# a DOUBLE PRECISION key is APPROXIMATE: both servers refuse and both
# files keep the same rows, and they differ only in how the refusal
# RENDERS the key - `7e0` against the engine's `7.000000000000000`.
# PRE-EXISTING (identical on the previous round's binary); both answers
# are pinned rather than skipped.
gap "16f contrast DOUBLE PRECISION key, DEFAULT 7 - approximate, not exact" \
    "CREATE TABLE DPP (ID DOUBLE PRECISION NOT NULL PRIMARY KEY);
     CREATE TABLE DPC (X INTEGER, B DOUBLE PRECISION DEFAULT 7,
                       CONSTRAINT DPK FOREIGN KEY (B) REFERENCES DPP ON DELETE SET DEFAULT);
     COMMIT; INSERT INTO DPP VALUES (7); INSERT INTO DPC VALUES (100, 7); COMMIT;
     DELETE FROM DPP WHERE ID = 7; COMMIT;
     SELECT COUNT(*) NP FROM DPP; SELECT B CB FROM DPC;" \
    'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "DPK" on table "PUBLIC"."DPC"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 7e0)|NP 1|CB 7.000000000000000|' \
    'Statement failed, SQLSTATE = 23000|violation of FOREIGN KEY constraint "DPK" on table "PUBLIC"."DPC"|-Foreign key references are present for the record|-Problematic key value is ("ID" = 7.000000000000000)|NP 1|CB 7.000000000000000|'
both "16f contrast a default that is a DIFFERENT key still lets the DELETE through" \
     "CREATE TABLE OKP (ID NUMERIC(9,2) NOT NULL PRIMARY KEY);
      CREATE TABLE OKC (X INTEGER, B NUMERIC(9,2) DEFAULT 8 REFERENCES OKP ON DELETE SET DEFAULT);
      COMMIT; INSERT INTO OKP VALUES (7.00); INSERT INTO OKP VALUES (8.00);
      INSERT INTO OKC VALUES (100, 7.00); COMMIT;
      DELETE FROM OKP WHERE ID = 7.00; COMMIT;
      SELECT COUNT(*) NP FROM OKP; SELECT B CB FROM OKC;"
# (g) a DECIMAL literal DEFAULT can now be CREATED at all. Until
# 2026-09-03 fire-crab's DDL refused `DEFAULT 7.00` and `DEFAULT 7.0`
# with a bare Dynamic SQL Error, so `DEFAULT 7` - the scale-0 spelling
# that (a) shows was the corrupting one - was the only decimal default
# it could write. The stored BLR is the engine's own scaled blr_long.
both "16g NUMERIC(9,2) DEFAULT 7.00 / 7.0 / -7.25, and a NUMERIC(9,4) one" \
     "CREATE TABLE FD (A INTEGER, B NUMERIC(9,2) DEFAULT 7.00, C NUMERIC(9,2) DEFAULT 7.0,
                       D NUMERIC(9,2) DEFAULT -7.25, E NUMERIC(9,4) DEFAULT 123456.7890);
      COMMIT; INSERT INTO FD (A) VALUES (1); COMMIT; SELECT B, C, D, E FROM FD;"
efiles "16g the stored RDB\$DEFAULT_SOURCE and RDB\$DEFAULT_VALUE BLR, byte for byte" \
     "SELECT TRIM(RF.RDB\$FIELD_NAME) || ' [' || CAST(RF.RDB\$DEFAULT_SOURCE AS VARCHAR(40)) || '] ' ||
             HEX_ENCODE(CAST(RF.RDB\$DEFAULT_VALUE AS VARBINARY(40))) D
        FROM RDB\$RELATION_FIELDS RF WHERE RF.RDB\$RELATION_NAME = 'FD'
          AND RF.RDB\$DEFAULT_VALUE IS NOT NULL ORDER BY RF.RDB\$FIELD_POSITION;" \
     'D B [DEFAULT 7.00] 051508FEBC0200004C|D C [DEFAULT 7.0] 051508FF460000004C|D D [DEFAULT -7.25] 051508FE2BFDFFFF4C|D E [DEFAULT 123456.7890] 051508FCD20296494C|' \
     'D B [DEFAULT 7.00] 051508FEBC0200004C|D C [DEFAULT 7.0] 051508FF460000004C|D D [DEFAULT -7.25] 051508FE2BFDFFFF4C|D E [DEFAULT 123456.7890] 051508FCD20296494C|'
both "16g a decimal DEFAULT driving ON DELETE SET DEFAULT - refused by both" \
     "CREATE TABLE FDP (ID NUMERIC(9,2) NOT NULL PRIMARY KEY);
      CREATE TABLE FDC (X INTEGER, B NUMERIC(9,2) DEFAULT 7.00 REFERENCES FDP ON DELETE SET DEFAULT);
      COMMIT; INSERT INTO FDP VALUES (7.00); INSERT INTO FDC VALUES (100, 7.00); COMMIT;
      DELETE FROM FDP WHERE ID = 7.00; COMMIT;
      SELECT COUNT(*) NP FROM FDP; SELECT B CB FROM FDC;"

# ---- 15. the file is sound ----------------------------------------------------
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
