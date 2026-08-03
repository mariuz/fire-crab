#!/bin/bash
# The server WRITES GENERATOR VALUES into the generator page. Two
# statements set a generator: SET GENERATOR <name> TO <n> stores n, and
# ALTER SEQUENCE <name> RESTART WITH <n> stores n - increment (so the
# next GEN_ID/NEXT VALUE FOR yields n). fire-crab locates the generator's
# slot (id % gensPerPage on the pag_ids page whose gpg_sequence is
# id / gensPerPage) and writes the native little-endian SINT64.
#
# The oracle is the REAL ENGINE. The SAME write statements are applied by
# fire-crab to one copy of a clean database and by the C++ engine to a
# second copy; afterwards each generator's stored value must be identical
# read from the fire-crab-written file and the engine-written file. The
# read is done two ways: by the engine's isql (SHOW GENERATORS reads the
# actual page value through GEN_ID) on both files, and back through
# fire-crab (SHOW GENERATORS via fcwire on its own written file) - so the
# write and the read-back both prove out. gfix must find nothing wrong
# with the file fire-crab wrote, and a SET on a nonexistent generator
# must raise an error, never a silent no-op.
#
# THE SECOND HALF - A GENERATOR DRAWN IN A DML STATEMENT. `UPDATE T SET V
# = GEN_ID(G,3)` and `DELETE FROM T WHERE ID = GEN_ID(G,1)` advance the
# sequence, and the number of advances is NOT "once per statement". The
# counting law, probed against the live engine and asserted phase by
# phase below:
#
#   a draw in the SET LIST advances ONCE PER UPDATED ROW - `SET V =
#        GEN_ID(G,3)` over 5 rows leaves 15 and stores 3,6,9,12,15;
#        behind a WHERE matching 2 of 5 it leaves 2 draws' worth; over a
#        WHERE matching none, and over an empty table, it leaves the
#        generator alone. The access path does not change this (an
#        index-driven range still draws once per row it updates).
#   a draw in the WHERE advances ONCE PER ROW COMPARED, matching or not -
#        `DELETE FROM T WHERE ID = GEN_ID(G,1)` over 5 rows leaves 5,
#        over 2 rows leaves 2, over an empty table leaves 0, and over a
#        predicate no row satisfies STILL leaves a full table's worth.
#   the WHERE's draw comes FIRST, per row, and the SET's follows only
#        when that row matched.
#   NEXT VALUE FOR is the same law in a different spelling; GEN_ID(g,0)
#        is a READ and advances nothing.
#   a statement that FAILS keeps the draws it had already made (the
#        durability law of serve-real-gendurable.sh, crossed with this
#        one here: an UPDATE raising on its FIRST row burns one draw and
#        on its SECOND burns two, with no row written either way).
#
# AND ONE PLACE WHERE IT ANSWERS A DIFFERENT NUMBER AND SAYS SO. The
# engine draws AS IT WALKS, so a statement that FAILS on row k has drawn
# exactly k times; fire-crab draws for every row while COLLECTING the
# targets and only then writes, so it has drawn for all of them. Four
# failing shapes are pinned as a RECORDED BOUNDARY below - both sides
# raise, both leave the rows alone, and the two draw counts are asserted
# as they stand TODAY (engine 1/2/2/2, fire-crab 3) so that either side
# moving is visible. Closing it means interleaving the draw with the
# WRITE walk, which is its own slice.
#
# AND WHERE fire-crab REFUSES rather than answer a different number.
# Three engine behaviours it cannot reproduce, each proved here to raise
# AND to leave the generator exactly where it stood:
#
#   AN INDEX RETRIEVAL CHANGES THE COUNT. With a PRIMARY KEY on ID,
#        `DELETE FROM TP WHERE ID = GEN_ID(G,1)` over 5 rows draws TWICE
#        and deletes NOTHING (the index bound is drawn, then the one
#        retrieved row is re-tested against a second draw); the same
#        statement under `PLAN (TP NATURAL)` draws 5 and deletes every
#        row. fire-crab cannot predict the engine's choice, so a WHERE
#        draw on a relation with ANY index refuses.
#   AND/OR SHORT-CIRCUIT. `WHERE ID > 99 AND ID = GEN_ID(G,1)` over 5
#        rows leaves the generator at 0 - the left conjunct is false
#        first and the draw is never reached - while the same two
#        conjuncts the other way round leave it at 5. The DNF the
#        predicate parser builds has lost that order, so a connective
#        beside a draw refuses.
#   THE DRAW IS MADE AS THE ROW IS WRITTEN. `UPDATE TP SET V =
#        GEN_ID(G,1), ID = 1` over 3 rows burns 2 draws - the second
#        row's write collides with the first row's new key and the third
#        row is never reached. fire-crab patches every matching image
#        (drawing as it goes) before the write walk judges uniqueness, so
#        it would burn 3. NOT NULL, CHECK and FK all raise inside the
#        patch loop and stop at the right row; uniqueness alone is
#        deferred, so a drawing SET list that rewrites a UNIQUE key over
#        a row set the WHERE has not pinned to ONE row refuses.
#
#   qa/serve-real-genwrite.sh [port]
#
# Builds its own scratch databases (three generators, one with a non-unit
# increment so RESTART WITH exercises the n - increment arithmetic; then a
# second database of index-free and indexed tables for the draws).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4098}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/genwrite_src.fdb"
WORK="/tmp/fc-genwrite-work.fdb"; REF="/tmp/fc-genwrite-ref.fdb"
# the DML-draw half: its own source and its own pair of twins
DSRC="$DIR/genwrite_drw.fdb"
DW="/tmp/fc-genwrite-dw.fdb"; DR="/tmp/fc-genwrite-dr.fdb"

mkdir -p "$DIR"
rm -f "$SRC" "$WORK" "$REF" "$DSRC" "$DW" "$DR"

# --- build the scratch database: three generators -----------------------
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE SEQUENCE SEQ_A;
CREATE SEQUENCE SEQ_INC INCREMENT BY 5;
CREATE GENERATOR GEN_C;
COMMIT;
EOF
cp "$SRC" "$WORK"
cp "$SRC" "$REF"

# --- build the DML-draw scratch database --------------------------------
# T/TN/TE carry NO INDEX AT ALL: with none the engine has only the
# natural walk, which is the one law fire-crab can reproduce. TP carries a
# PRIMARY KEY, and is here to prove the REFUSAL.
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL draw db creation"; exit 1; }
CREATE DATABASE '$DSRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
CREATE TABLE TN (ID INTEGER, V INTEGER);
CREATE TABLE TE (ID INTEGER, V INTEGER);
CREATE TABLE TP (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
CREATE TABLE TNN (ID INTEGER NOT NULL, V INTEGER);
CREATE TABLE TCK (ID INTEGER, V INTEGER, CONSTRAINT CK_TCK CHECK (V < 100));
CREATE SEQUENCE G1;
CREATE SEQUENCE G2;
CREATE SEQUENCE G5 INCREMENT BY 5;
COMMIT;
INSERT INTO T VALUES (1,10);
INSERT INTO T VALUES (2,20);
INSERT INTO T VALUES (3,30);
INSERT INTO T VALUES (4,40);
INSERT INTO T VALUES (5,50);
INSERT INTO TN VALUES (1,10);
INSERT INTO TN (V) VALUES (20);
INSERT INTO TN VALUES (3,30);
INSERT INTO TP VALUES (1,10);
INSERT INTO TP VALUES (2,20);
INSERT INTO TP VALUES (3,30);
INSERT INTO TNN VALUES (1,10);
INSERT INTO TNN VALUES (2,20);
INSERT INTO TNN VALUES (3,30);
INSERT INTO TCK VALUES (1,10);
INSERT INTO TCK VALUES (2,20);
INSERT INTO TCK VALUES (3,30);
COMMIT;
EOF
chmod 666 "$DSRC"

# the write statements, applied identically to both copies
WRITES="SET GENERATOR GEN_C TO 4242;
ALTER SEQUENCE SEQ_A RESTART WITH 7;
ALTER SEQUENCE SEQ_INC RESTART WITH 100;
SET GENERATOR GEN_C TO 999;
SET GENERATOR SEQ_A TO -3;
COMMIT;"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-genwrite.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$DSRC" "$DW" "$DR"' EXIT
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
sleep 0.5

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

# apply the writes through fire-crab (to WORK). isql's own COMMIT chatter
# is irrelevant; what matters is the stored values afterwards. Retry the
# whole session on a transient cold-start connection error.
apply_fc() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
              "localhost/$PORT:$WORK" 2>&1 <<EOF
$WRITES
EOF
)
        case "$r" in
            *08006*|*28000*|*"Unable to complete"*|*"connection rejected"*)
                cp "$SRC" "$WORK"; n=$((n + 1)); sleep 0.3 ;;
            *) return 0 ;;
        esac
    done
    return 1
}
apply_fc || { echo "FAIL could not apply writes through fire-crab"; exit 1; }

# apply the SAME writes through the engine (to REF)
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$WRITES
EOF

fail=0
ran=0
compare() { # <label> <expected> <actual>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $2"
        echo "     fc:     $3"
        fail=1
    fi
}

# 1) the engine reads identical stored values from the fire-crab-written
#    file and the engine-written file (the pure write oracle)
en_ref=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF | strip
SHOW GENERATORS;
EOF
)
en_work=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF | strip
SHOW GENERATORS;
EOF
)
compare "engine reads fc-written == engine-written" "$en_ref" "$en_work"

# spot the exact expected values (non-vacuity: assert the numbers moved)
vals=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF | strip
SELECT GEN_ID(GEN_C,0)||'/'||GEN_ID(SEQ_A,0)||'/'||GEN_ID(SEQ_INC,0) FROM RDB\$DATABASE;
EOF
)
# GEN_C: last SET wins (999); SEQ_A: SET TO -3 after RESTART 7 (-3);
# SEQ_INC: RESTART WITH 100, increment 5 -> 95
compare "stored values GEN_C/SEQ_A/SEQ_INC" "999/-3/95" "$(echo "$vals" | grep -oE '[-0-9]+/[-0-9]+/[-0-9]+')"

# 2) read the values back THROUGH fire-crab (SHOW GENERATORS via fcwire on
#    its own written file) - the write and read-back both prove out.
#    Retry on the transient cold-start connection/auth race.
fc_show_cmd() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
              "localhost/$PORT:$WORK" 2>&1 <<EOF
SHOW GENERATORS;
EOF
)
        case "$r" in
            *08006*|*28000*|*"Unable to complete"*|*"connection rejected"*|"")
                n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r"; return ;;
        esac
    done
    printf '%s\n' "$r"
}
fc_show=$(fc_show_cmd | strip)
compare "fire-crab reads back its own writes" "$en_ref" "$fc_show"

# 3) gfix finds nothing wrong with the file fire-crab wrote
gfix_out=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
compare "gfix -v -full clean after generator writes" "" "$(echo "$gfix_out" | strip)"

# 4) a SET on a nonexistent generator must raise an error, not silently
#    do nothing (isql prints the SQLSTATE/error text)
err=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
        "localhost/$PORT:$WORK" 2>&1 <<EOF
SET GENERATOR NO_SUCH_GEN TO 5;
EOF
)
case "$err" in
    *error*|*Error*|*failed*|*SQLSTATE*)
        ran=$((ran + 1)); echo "OK   SET on nonexistent generator raises an error" ;;
    *)
        ran=$((ran + 1)); echo "DIFF SET on nonexistent generator raises an error"
        echo "     got: $err"; fail=1 ;;
esac

# ========================================================================
# THE SECOND HALF: A GENERATOR DRAWN IN A DML STATEMENT
# ========================================================================
# Same oracle, same shape as serve-real-gendurable.sh: one script runs
# against fresh twins - fire-crab's copy through fcwire, the engine's copy
# direct - and the ENGINE then reads BOTH files back. Every phase compares
# all three generators' STORED values AND every table's rows. Rows alone
# would pass a statement that touched the right records over a generator
# left in the wrong place, which is exactly the wrong answer this slice
# exists to catch.

# the engine reading a generator's stored value out of whichever file it
# is pointed at - through the ODS, never through fire-crab's answer
dgen_of() { # <file> <generator>
    printf 'SET HEADING OFF;\nSELECT GEN_ID(%s, 0) FROM RDB$DATABASE;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
ddump() { # <file>
    printf 'SET HEADING OFF;
SELECT ID, COALESCE(V,-9) FROM T ORDER BY ID, V;
SELECT COALESCE(ID,-9), COALESCE(V,-9) FROM TN ORDER BY ID, V;
SELECT ID, COALESCE(V,-9) FROM TE ORDER BY ID, V;
SELECT ID, COALESCE(V,-9) FROM TP ORDER BY ID, V;
SELECT ID, COALESCE(V,-9) FROM TNN ORDER BY ID, V;
SELECT COALESCE(ID,-9), COALESCE(V,-9) FROM TCK ORDER BY ID, V;
' | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
ddrive() { # <script> - run it through BOTH sides on fresh twins
    rm -f "$DW" "$DR"; cp "$DSRC" "$DW"; cp "$DSRC" "$DR"
    printf '%s\n' "$1" | timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" \
        "127.0.0.1/$PORT:$DW" >/dev/null 2>&1
    printf '%s\n' "$1" | timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" \
        "$DR" >/dev/null 2>&1
}
dsame() { # <label> <script>
    ddrive "$2"
    for g in G1 G2 G5; do
        compare "$1 | stored $g" "$(dgen_of "$DR" "$g")" "$(dgen_of "$DW" "$g")"
    done
    compare "$1 | rows" "$(ddump "$DR")" "$(ddump "$DW")"
}
# THE TEETH: the symmetric compare above passes when BOTH sides get it
# wrong the same way, so every counting claim is also pinned to the
# ENGINE'S OWN NUMBER, read out of fire-crab's file.
dteeth() { # <label> <generator> <want> <script>
    ddrive "$4"
    compare "teeth: $1" "$3" "$(dgen_of "$DW" "$2" | tr -d ' ')"
}
# THE REFUSAL: fire-crab must RAISE, and must leave the generator and the
# rows exactly as it found them. A refusal is visible to the client; a
# silently different number of advances is not.
drefuse() { # <label> <generator> <statement>
    rm -f "$DW"; cp "$DSRC" "$DW"
    before_g=$(dgen_of "$DW" "$2"); before_r=$(ddump "$DW")
    out=$(printf 'SET AUTODDL OFF;\n%s;\nCOMMIT;\n' "$3" |
        timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" \
            "127.0.0.1/$PORT:$DW" 2>&1)
    ran=$((ran + 1))
    case "$out" in
        *SQLSTATE*|*error*|*Error*|*failed*)
            echo "OK   refuses: $1" ;;
        *)  echo "DIFF refuses: $1 - fire-crab ANSWERED [$out]"; fail=1 ;;
    esac
    compare "refuses: $1 | generator untouched" "$before_g" "$(dgen_of "$DW" "$2")"
    compare "refuses: $1 | rows untouched" "$before_r" "$(ddump "$DW")"
}

# --- the SET-LIST draw: once per UPDATED row ----------------------------
dsame "UPDATE SET V = GEN_ID(G1,3) over 5 rows" \
    "UPDATE T SET V = GEN_ID(G1,3);
COMMIT;"
dteeth "5 updated rows, step 3 -> 15" G1 15 \
    "UPDATE T SET V = GEN_ID(G1,3);
COMMIT;"
dsame "UPDATE SET V = GEN_ID(G1,3) over 2 of 5 rows" \
    "UPDATE T SET V = GEN_ID(G1,3) WHERE ID <= 2;
COMMIT;"
dteeth "the WHERE gates the draw: 2 matching rows -> 6" G1 6 \
    "UPDATE T SET V = GEN_ID(G1,3) WHERE ID <= 2;
COMMIT;"
dsame "UPDATE SET V = GEN_ID(G1,1) matching NO row" \
    "UPDATE T SET V = GEN_ID(G1,1) WHERE ID > 99;
COMMIT;"
dteeth "a zero-row UPDATE draws nothing" G1 0 \
    "UPDATE T SET V = GEN_ID(G1,1) WHERE ID > 99;
COMMIT;"
dsame "UPDATE SET V = GEN_ID(G1,1) over an EMPTY table" \
    "UPDATE TE SET V = GEN_ID(G1,1);
COMMIT;"
dteeth "an empty table draws nothing" G1 0 \
    "UPDATE TE SET V = GEN_ID(G1,1);
COMMIT;"
dsame "UPDATE SET V = NEXT VALUE FOR G1 (the other spelling)" \
    "UPDATE T SET V = NEXT VALUE FOR G1;
COMMIT;"
dsame "NEXT VALUE FOR an INCREMENT BY 5 sequence, per row" \
    "UPDATE T SET V = NEXT VALUE FOR G5;
COMMIT;"
dteeth "5 rows x the declared increment 5 -> 21 (slot -4 + 5x5)" G5 21 \
    "UPDATE T SET V = NEXT VALUE FOR G5;
COMMIT;"
dsame "GEN_ID(G1,0) in a SET list is a READ, not an advance" \
    "SELECT GEN_ID(G1,4) FROM RDB\$DATABASE;
COMMIT;
UPDATE T SET V = GEN_ID(G1,0);
COMMIT;"
dteeth "a zero step stores the value and moves nothing" G1 4 \
    "SELECT GEN_ID(G1,4) FROM RDB\$DATABASE;
COMMIT;
UPDATE T SET V = GEN_ID(G1,0);
COMMIT;"
dsame "a NEGATIVE step, once per updated row" \
    "UPDATE T SET V = GEN_ID(G1,-2);
COMMIT;"
dsame "two UPDATEs in a row keep advancing the same sequence" \
    "UPDATE T SET V = GEN_ID(G1,1);
UPDATE T SET V = GEN_ID(G1,1);
COMMIT;"
dsame "a SET-list draw on an INDEXED table (the path does not gate it)" \
    "UPDATE TP SET V = GEN_ID(G1,1);
COMMIT;"
dsame "a SET-list draw behind an INDEXED range" \
    "UPDATE TP SET V = GEN_ID(G1,1) WHERE ID > 1;
COMMIT;"

# --- the WHERE draw: once per ROW COMPARED ------------------------------
dsame "DELETE WHERE ID = GEN_ID(G1,1) over 5 rows" \
    "DELETE FROM T WHERE ID = GEN_ID(G1,1);
COMMIT;"
dteeth "5 rows COMPARED -> 5, however many matched" G1 5 \
    "DELETE FROM T WHERE ID = GEN_ID(G1,1);
COMMIT;"
dsame "DELETE WHERE ID = GEN_ID(G1,1) over 3 rows, one with a NULL ID" \
    "DELETE FROM TN WHERE ID = GEN_ID(G1,1);
COMMIT;"
dteeth "a NULL column compares UNKNOWN but has already DRAWN" G1 3 \
    "DELETE FROM TN WHERE ID = GEN_ID(G1,1);
COMMIT;"
dsame "DELETE WHERE ID = GEN_ID(G1,1) over an EMPTY table" \
    "DELETE FROM TE WHERE ID = GEN_ID(G1,1);
COMMIT;"
dteeth "no row compared, no draw" G1 0 \
    "DELETE FROM TE WHERE ID = GEN_ID(G1,1);
COMMIT;"
dsame "DELETE WHERE ID > GEN_ID(G1,1) - 5 draws, 0 rows" \
    "DELETE FROM T WHERE ID > GEN_ID(G1,1);
COMMIT;"
dteeth "a predicate NO row satisfies still draws per row" G1 5 \
    "DELETE FROM T WHERE ID > GEN_ID(G1,1);
COMMIT;"
dsame "DELETE WHERE ID <> GEN_ID(G1,1)" \
    "DELETE FROM T WHERE ID <> GEN_ID(G1,1);
COMMIT;"
dsame "the draw written on the LEFT: WHERE GEN_ID(G1,1) = ID" \
    "DELETE FROM T WHERE GEN_ID(G1,1) = ID;
COMMIT;"
dsame "DELETE WHERE ID = NEXT VALUE FOR G1" \
    "DELETE FROM T WHERE ID = NEXT VALUE FOR G1;
COMMIT;"
dsame "an UPDATE whose WHERE draws" \
    "UPDATE T SET V = 777 WHERE ID = GEN_ID(G1,1);
COMMIT;"
dteeth "an UPDATE's WHERE draws per row compared too" G1 5 \
    "UPDATE T SET V = 777 WHERE ID = GEN_ID(G1,1);
COMMIT;"
dsame "TWO sequences at once: the SET's and the WHERE's" \
    "UPDATE T SET V = GEN_ID(G1,1) WHERE ID = GEN_ID(G2,1);
COMMIT;"
dteeth "the SET draws per MATCHED row..." G1 5 \
    "UPDATE T SET V = GEN_ID(G1,1) WHERE ID = GEN_ID(G2,1);
COMMIT;"
dteeth "...while the WHERE draws per COMPARED row" G2 5 \
    "UPDATE T SET V = GEN_ID(G1,1) WHERE ID = GEN_ID(G2,1);
COMMIT;"
dsame "the WHERE's draw comes FIRST, the SET's only if the row matched" \
    "UPDATE TN SET V = NEXT VALUE FOR G1 WHERE ID = GEN_ID(G2,1);
COMMIT;"
dteeth "3 rows compared, 2 matched: the SET side" G1 2 \
    "UPDATE TN SET V = NEXT VALUE FOR G1 WHERE ID = GEN_ID(G2,1);
COMMIT;"

# --- UPDATE OR INSERT, both halves --------------------------------------
dsame "UPDATE OR INSERT drawing, the UPDATE half taking it" \
    "UPDATE OR INSERT INTO TP (ID,V) VALUES (3, GEN_ID(G1,1)) MATCHING (ID);
COMMIT;"
dsame "UPDATE OR INSERT drawing, the INSERT half taking it" \
    "UPDATE OR INSERT INTO TP (ID,V) VALUES (9, GEN_ID(G1,1)) MATCHING (ID);
COMMIT;"
dteeth "either half draws exactly once" G1 1 \
    "UPDATE OR INSERT INTO TP (ID,V) VALUES (9, GEN_ID(G1,1)) MATCHING (ID);
COMMIT;"

# --- crossed with the DURABILITY BURN -----------------------------------
# serve-real-gendurable.sh owns the law that a draw survives an undo. It
# had only INSERT draws to prove it with; these are the UPDATE and DELETE
# ones, and the failing-statement phases are the interesting half - the
# rows go back and the draws made before the raise do not.
dsame "an UPDATE that drew, then ROLLBACK" \
    "UPDATE T SET V = GEN_ID(G1,3);
ROLLBACK;"
dteeth "the rows retreat, the 5 draws BURN" G1 15 \
    "UPDATE T SET V = GEN_ID(G1,3);
ROLLBACK;"
dsame "a DELETE whose WHERE drew, then ROLLBACK" \
    "DELETE FROM T WHERE ID = GEN_ID(G1,1);
ROLLBACK;"
dteeth "an undone DELETE still burns its comparisons" G1 5 \
    "DELETE FROM T WHERE ID = GEN_ID(G1,1);
ROLLBACK;"
dsame "an UPDATE that FAILS on the FIRST row (NOT NULL)" \
    "UPDATE TNN SET V = GEN_ID(G1,1), ID = NULL;
COMMIT;"
dteeth "the first row's draw is made BEFORE the row is validated" G1 1 \
    "UPDATE TNN SET V = GEN_ID(G1,1), ID = NULL;
COMMIT;"
dsame "an UPDATE that FAILS on the SECOND row (NOT NULL)" \
    "UPDATE TNN SET V = GEN_ID(G1,1), ID = 1 / (ID - 2);
COMMIT;"
dteeth "two rows reached before the raise: two draws burn" G1 2 \
    "UPDATE TNN SET V = GEN_ID(G1,1), ID = 1 / (ID - 2);
COMMIT;"
dsame "a failed draw, then a kept one" \
    "UPDATE TNN SET V = GEN_ID(G1,1), ID = NULL;
UPDATE T SET V = GEN_ID(G1,1);
COMMIT;"
dsame "an absolute SET GENERATOR meeting a DML draw" \
    "SET AUTODDL OFF;
UPDATE T SET V = GEN_ID(G1,1);
SET GENERATOR G1 TO 3;
ROLLBACK;"
dsame "a DML draw made AFTER an absolute set, then rolled back" \
    "SET AUTODDL OFF;
SET GENERATOR G1 TO 3;
UPDATE T SET V = GEN_ID(G1,1);
ROLLBACK;"

# --- A RECORDED BOUNDARY: THE FAILING WALK'S DRAW COUNT ----------------
# BOTH SIDES RAISE, AND THE NUMBER OF DRAWS BEHIND THE RAISE DIFFERS.
#
# The engine DRAWS AS IT WALKS: a statement that fails on row k has drawn
# exactly k times, because the k-th row's draw, its test, its patch and
# its write all happen before the (k+1)-th row is read. fire-crab draws
# for EVERY row while it COLLECTS the targets and only then runs the
# write walk, so a raise anywhere in the walk still has a full table's
# draws behind it. Rows are identical on both sides (the statement is
# atomic either way, and the re-read below proves it through the ENGINE);
# only the generator diverges, and a client that reads the sequence back
# after a failed statement sees a different number.
#
# CLOSING IT means interleaving the draw with the WRITE walk - drawing
# the k-th row's value at the moment that row is patched rather than
# during collection - which is the same reshaping Inc366 did for
# uniqueness enforcement, and its own slice. Until then the numbers are
# PINNED ON BOTH SIDES so that either one moving is visible: the engine's
# number is the law, fire-crab's is the debt.
#
# This is NOT a regression of the DML-draw slice. The HEAD binary before
# it answered 0 here - it had no WHERE draw at all - so the slice made an
# already-wrong cell wrong differently, and this records where it landed.
dbound() { # <label> <engine-draws> <fc-draws> <statement>
    rm -f "$DW" "$DR"; cp "$DSRC" "$DW"; cp "$DSRC" "$DR"
    ofc=$(printf 'SET AUTODDL OFF;\n%s;\nCOMMIT;\n' "$4" |
        timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" \
            "127.0.0.1/$PORT:$DW" 2>&1)
    oen=$(printf 'SET AUTODDL OFF;\n%s;\nCOMMIT;\n' "$4" |
        timeout -s KILL 30 "$ISQL" -q -user "$U" -pas "$P" "$DR" 2>&1)
    ran=$((ran + 1))
    case "$ofc" in *SQLSTATE*) ;; *)
        echo "DIFF boundary: $1 - fire-crab did NOT raise [$ofc]"; fail=1 ;;
    esac
    case "$oen" in *SQLSTATE*) ;; *)
        echo "DIFF boundary: $1 - the ENGINE did not raise [$oen]"; fail=1 ;;
    esac
    echo "BOUND $1 (engine draws $2, fire-crab $3)"
    # the rows must still agree - a divergent COUNT is the whole boundary,
    # a divergent TABLE would be a wrong write
    compare "boundary: $1 | rows" "$(ddump "$DR")" "$(ddump "$DW")"
    compare "boundary: $1 | the ENGINE's count is still $2" "$2" \
        "$(dgen_of "$DR" G1 | tr -d ' ')"
    compare "boundary: $1 | fire-crab's count is still $3" "$3" \
        "$(dgen_of "$DW" G1 | tr -d ' ')"
}
dbound "a WHERE draw whose row 1 fails NOT NULL" 1 3 \
    "UPDATE TNN SET ID = NULL WHERE ID = GEN_ID(G1,1)"
dbound "a WHERE draw whose row 2 fails a CHECK" 2 3 \
    "UPDATE TCK SET V = ID * 50 WHERE ID = GEN_ID(G1,1)"
dbound "a WHERE draw whose row 2 divides by zero" 2 3 \
    "UPDATE TNN SET V = 1 / (ID - 2) WHERE ID = GEN_ID(G1,1)"
# the same law inside ONE row's SET list: the engine evaluates the items
# in WRITTEN order, so a raise in the FIRST item happens before the
# SECOND one draws - row 3 raises having drawn twice, not three times
dbound "a SET-list draw behind an item that raises on row 3" 2 3 \
    "UPDATE TNN SET ID = 1 / (ID - 3), V = GEN_ID(G1,1)"

# --- WHERE fire-crab REFUSES --------------------------------------------
drefuse "a WHERE draw on an INDEXED relation (the engine's count is path-dependent)" \
    G1 "DELETE FROM TP WHERE ID = GEN_ID(G1,1)"
drefuse "a WHERE draw on an INDEXED relation, the UPDATE spelling" \
    G1 "UPDATE TP SET V = 1 WHERE ID = GEN_ID(G1,1)"
drefuse "a draw beside AND (the engine short-circuits)" \
    G1 "DELETE FROM T WHERE ID > 99 AND ID = GEN_ID(G1,1)"
drefuse "a draw beside OR" \
    G1 "DELETE FROM T WHERE ID < 99 OR ID = GEN_ID(G1,1)"
drefuse "the SAME sequence in the SET list and the WHERE (the draws interleave)" \
    G1 "UPDATE T SET V = GEN_ID(G1,1) WHERE ID = GEN_ID(G1,1)"
drefuse "a draw buried in a larger SET expression" \
    G1 "UPDATE T SET V = GEN_ID(G1,1) + 100"
drefuse "a draw buried in a larger WHERE expression" \
    G1 "DELETE FROM T WHERE ID = 99 + GEN_ID(G1,1)"
drefuse "a draw in a RETURNING clause" \
    G2 "UPDATE T SET V = 1 RETURNING GEN_ID(G2,1)"
drefuse "a drawing SET list that rewrites a UNIQUE key over more than one row" \
    G1 "UPDATE TP SET V = GEN_ID(G1,1), ID = 1"
drefuse "a SET-list draw from a sequence that does not exist" \
    G1 "UPDATE T SET V = GEN_ID(NO_SUCH_GEN,1)"
drefuse "a WHERE draw from a sequence that does not exist" \
    G1 "DELETE FROM T WHERE ID = GEN_ID(NO_SUCH_GEN,1)"

# --- the file the draws wrote is still a database -----------------------
ddrive "UPDATE T SET V = GEN_ID(G1,3);
DELETE FROM TN WHERE ID = GEN_ID(G2,1);
COMMIT;"
compare "gfix -v -full clean after DML generator draws" "" \
    "$("$GFIX" -v -full -user "$U" -pas "$P" "$DW" 2>&1 | strip)"

echo "ran $ran"
exit $fail
