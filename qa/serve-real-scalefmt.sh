#!/bin/bash
# A ROW STORED BEFORE `ALTER ... TYPE` MUST READ BACK AS ITS NUMBER.
#
# `ALTER TABLE T ALTER c TYPE <scaled>` mints a format and rewrites NOT
# ONE ROW. An exact numeric is stored as a MANTISSA and its DESCRIPTOR
# carries the scale, so a record written when `N` was `INTEGER` holds
# `700` where a record written after `ALTER ... TYPE NUMERIC(9,2)` holds
# `70000` for the same number. Reading the first one and projecting it
# through the NEW descriptor - which is what the wire does, shipping the
# raw mantissa and letting the client divide by `10^|scale|` - answered
# `7.00` for a stored `700.00`, and `0.07` for a stored `7.00`. Every row
# written before the ALTER was wrong by the scale factor.
#
# THIS GATE COMPARES PROJECTED VALUES, and that is the point of it: no
# gate in qa/ did. `qa/serve-real-stalefmt.sh` is the gate for old-format
# rows and it says so, but every ALTER in its fixture PRESERVES the scale
# (`INTEGER` -> `BIGINT`, `NUMERIC(9,2)` -> `NUMERIC(18,2)`), so the one
# thing that can go wrong here cannot happen there; and of the eight
# gates that contain an `ALTER ... TYPE`, none contains a `GROUP BY` or a
# `DISTINCT`. So the wrong answer below was invisible to all 85 gates.
#
# It also covers the direction the reproducer does NOT reach. The engine
# accepts an ALTER that keeps the integral digits and DROPS decimals
# (`NUMERIC(9,2)` -> `INTEGER`, `-> BIGINT`, `-> NUMERIC(18,1)`; it
# refuses `-> NUMERIC(9,4)` with "New scale specified for column N must
# be at most 2"), and reading those rows back it ROUNDS HALF AWAY FROM
# ZERO. Section D measures that rule against the engine rather than
# asserting a chosen one.
#
# RECORDED DIVERGENCES, both answers pinned so neither server can change
# its mind unnoticed:
#   * `LIST` renders a different BLOB ID (`0:40000001` vs `0:1`); the
#     CONTENT is compared instead and is identical.
#   * fire-crab's LOGICAL BACKUP loses a scaled column's SCALE: att 9 of
#     a burp field record is RDB$FIELD_SUB_TYPE and att 11 is
#     RDB$FIELD_SCALE, and this writer has them swapped, so a
#     `NUMERIC(9,2)` restores through the REAL `gbak -c` as an INTEGER
#     holding the mantissa. PRE-EXISTING and independent of any ALTER -
#     section F pins it on a table that was never ALTERed. What section F
#     DOES assert as the engine's own answer is the scale-preserving
#     widening (`INTEGER` -> `BIGINT`), where the backup used to restore
#     the pre-ALTER rows as `0`.
#
#   qa/serve-real-scalefmt.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
FBSVCMGR="${FBSVCMGR:-fbsvcmgr}"
PORT="${1:-4952}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-scalefmt-crab.fdb"
B="$D/fc-scalefmt-engine.fdb"
G="$D/fc-scalefmt-bk.fdb"
LOG="/tmp/fc-serve-scalefmt-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE M6  (ID INTEGER, N INTEGER);
CREATE TABLE IXM (ID INTEGER, N INTEGER);
CREATE TABLE MW  (ID INTEGER, N INTEGER);
CREATE TABLE M4  (ID INTEGER, N NUMERIC(9,2));
CREATE TABLE NR0 (ID INTEGER, N NUMERIC(9,2));
CREATE TABLE NR1 (ID INTEGER, N NUMERIC(9,2));
CREATE TABLE SM  (ID INTEGER, N SMALLINT);
CREATE TABLE TRG (ID INTEGER, N INTEGER);
CREATE TABLE LOG (ID INTEGER, V NUMERIC(9,2));
CREATE TABLE MG  (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER);
CREATE TABLE CTL (ID INTEGER, N NUMERIC(9,2));
CREATE TABLE IW  (ID INTEGER, N INTEGER);
COMMIT;
CREATE INDEX IWN ON IW (N);
COMMIT;
INSERT INTO M6 VALUES (1,700);  INSERT INTO M6 VALUES (2,7);
INSERT INTO M6 VALUES (5,NULL);
INSERT INTO IXM VALUES (1,700); INSERT INTO IXM VALUES (2,7);
INSERT INTO MW VALUES (1,700);  INSERT INTO MW VALUES (2,7);
INSERT INTO M4 VALUES (1,7.00); INSERT INTO M4 VALUES (2,-2.50);
INSERT INTO NR0 VALUES (1,7.55); INSERT INTO NR0 VALUES (2,7.45);
INSERT INTO NR0 VALUES (3,7.50); INSERT INTO NR0 VALUES (4,8.50);
INSERT INTO NR0 VALUES (5,-7.55); INSERT INTO NR0 VALUES (6,-7.50);
INSERT INTO NR0 VALUES (7,0.49);  INSERT INTO NR0 VALUES (8,-0.51);
INSERT INTO NR0 VALUES (9,-7.45); INSERT INTO NR0 VALUES (10,-0.01);
INSERT INTO NR1 VALUES (1,7.55); INSERT INTO NR1 VALUES (2,7.45);
INSERT INTO NR1 VALUES (3,7.05); INSERT INTO NR1 VALUES (4,-7.55);
INSERT INTO NR1 VALUES (5,-7.45); INSERT INTO NR1 VALUES (6,-7.05);
INSERT INTO SM VALUES (1,700);  INSERT INTO SM VALUES (2,-7);
INSERT INTO TRG VALUES (1,700); INSERT INTO TRG VALUES (2,7);
INSERT INTO MG VALUES (1,700);  INSERT INTO MG VALUES (2,7);
INSERT INTO CTL VALUES (1,7.00); INSERT INTO CTL VALUES (2,700.00);
INSERT INTO IW VALUES (1,700); INSERT INTO IW VALUES (2,7);
COMMIT;
ALTER TABLE M6  ALTER N TYPE NUMERIC(9,2);
ALTER TABLE IXM ALTER N TYPE NUMERIC(9,2);
ALTER TABLE MW  ALTER N TYPE NUMERIC(20,2);
ALTER TABLE M4  ALTER N TYPE NUMERIC(20,4);
ALTER TABLE NR0 ALTER N TYPE INTEGER;
ALTER TABLE NR1 ALTER N TYPE NUMERIC(18,1);
ALTER TABLE SM  ALTER N TYPE NUMERIC(9,2);
ALTER TABLE TRG ALTER N TYPE NUMERIC(9,2);
ALTER TABLE MG  ALTER N TYPE NUMERIC(9,2);
ALTER TABLE IW  ALTER N TYPE NUMERIC(9,2);
COMMIT;
CREATE INDEX IXMN ON IXM (N);
COMMIT;
INSERT INTO M6 VALUES (3,7.00);  INSERT INTO M6 VALUES (4,700.00);
INSERT INTO IXM VALUES (3,7.00); INSERT INTO IXM VALUES (4,700.00);
INSERT INTO MW VALUES (3,7.00);  INSERT INTO MW VALUES (4,700.00);
INSERT INTO M4 VALUES (3,7.0000);
INSERT INTO NR0 VALUES (99,7);
INSERT INTO NR1 VALUES (99,7.5);
INSERT INTO SM VALUES (3,7.00);
INSERT INTO TRG VALUES (3,7.00);
INSERT INTO MG VALUES (3,7.00);
INSERT INTO IW VALUES (3,7.00); INSERT INTO IW VALUES (4,700.00);
COMMIT;
SET TERM ^ ;
CREATE TRIGGER TRGAD FOR TRG AFTER DELETE AS
BEGIN INSERT INTO LOG VALUES (OLD.ID, OLD.N); END^
SET TERM ; ^
COMMIT;
EOF
    chmod 666 "$1"; }

# the BACKUP fixture is separate: it holds only what this server's
# logical-backup surface carries (no trigger, no primary key, no INT128)
make_bk() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE W6 (ID INTEGER, N INTEGER);
CREATE TABLE S6 (ID INTEGER, N INTEGER);
CREATE TABLE PL (ID INTEGER, N NUMERIC(9,2));
COMMIT;
INSERT INTO W6 VALUES (1,700); INSERT INTO W6 VALUES (2,7);
INSERT INTO S6 VALUES (1,700); INSERT INTO S6 VALUES (2,7);
INSERT INTO PL VALUES (1,700.00);
COMMIT;
ALTER TABLE W6 ALTER N TYPE BIGINT;
ALTER TABLE S6 ALTER N TYPE NUMERIC(9,2);
COMMIT;
INSERT INTO W6 VALUES (3,7); INSERT INTO W6 VALUES (4,700);
INSERT INTO S6 VALUES (3,7.00); INSERT INTO S6 VALUES (4,700.00);
COMMIT;
EOF
    chmod 666 "$1"; }

# a THIRD backup fixture, on its own because the answer it pins is a
# REFUSAL OF THE WHOLE BACKUP: a column ADDED after the rows were
# written, whose value lives in the format's DEFAULT section
make_ac() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE AC (ID INTEGER, N INTEGER);
COMMIT;
INSERT INTO AC VALUES (1,7); INSERT INTO AC VALUES (2,8);
COMMIT;
ALTER TABLE AC ADD C INTEGER;
ALTER TABLE AC ADD DFT INTEGER DEFAULT 99 NOT NULL;
COMMIT;
INSERT INTO AC VALUES (3,9,5,4);
COMMIT;
EOF
    chmod 666 "$1"; }

make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
make_bk "$G" || { echo "FAIL scratch G"; exit 1; }
make_ac "$D/fc-scalefmt-ac.fdb" || { echo "FAIL scratch AC"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$G" "$D"/fc-scalefmt-ac.fdb "$D"/fc-scalefmt-*.fbk "$D"/fc-scalefmt-r*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
crabq()   { printf 'SET LIST ON;\n%s\n' "$1" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm; }
engineq() { printf 'SET LIST ON;\n%s\n' "$1" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm; }
both() { check "$1" "$(crabq "$2")" "$(engineq "$2")"; }
# a shape where the two DIFFER and the difference is RECORDED: both
# answers are pinned, so this is not a way to stop comparing
gap() {
    check "$1 - fire-crab's answer (a recorded gap)" "$(crabq "$2")" "$3"
    check "$1 - the ENGINE's own answer"             "$(engineq "$2")" "$4"
}

# ---------------------------------------------------------------- A
# THE PROJECTION ITSELF. Ids 1 and 2 were written under `INTEGER`, ids 3
# and 4 after the ALTER; the engine reads all four as the same two
# numbers. This is the whole defect, in one statement.
both "A1 M6 projects its numbers"   "SELECT ID, N FROM M6 ORDER BY ID;"
both "A2 the pre-ALTER rows alone"  "SELECT N FROM M6 WHERE ID IN (1,2) ORDER BY ID;"
both "A3 a NULL stays NULL"         "SELECT ID, N FROM M6 WHERE N IS NULL;"
both "A4 the control, never ALTERed" "SELECT ID, N FROM CTL ORDER BY ID;"
both "A5 SMALLINT source"           "SELECT ID, N FROM SM ORDER BY ID;"
both "A6 CAST to text"              "SELECT ID, CAST(N AS VARCHAR(20)) T FROM M6 ORDER BY ID;"
both "A7 arithmetic over a stale row" "SELECT ID, N + 1 A, N * 2 B FROM M6 ORDER BY ID;"

# ---------------------------------------------------------------- B
# DISTINCT, GROUP BY, THE AGGREGATES AND THE WINDOW - where the wrong
# projection cost ROWS, not just digits: the comparison collapsed an
# old-format row with a new-format one and then projected the group's
# representative, which is the FIRST row seen. `700.00` disappeared from
# the answer entirely.
both "B1 SELECT DISTINCT"           "SELECT DISTINCT N FROM M6 ORDER BY 1;"
both "B2 GROUP BY with the key"     "SELECT N, COUNT(*) C FROM M6 GROUP BY N ORDER BY 1;"
both "B3 GROUP BY ... HAVING"       "SELECT N, COUNT(*) C FROM M6 GROUP BY N HAVING MAX(N) >= 700 ORDER BY 1;"
both "B4 SUM / MIN / MAX / AVG"     "SELECT SUM(N) S, MIN(N) MN, MAX(N) MX, AVG(N) AV FROM M6;"
both "B5 COUNT(DISTINCT)"           "SELECT COUNT(DISTINCT N) C FROM M6;"
both "B6 the window functions"      "SELECT ID, N, RANK() OVER (ORDER BY N) R, DENSE_RANK() OVER (ORDER BY N) DR, COUNT(*) OVER (PARTITION BY N) CW, SUM(N) OVER (PARTITION BY N) SW FROM M6 ORDER BY ID;"
both "B7 LAG over the partition"    "SELECT ID, LAG(ID) OVER (PARTITION BY N ORDER BY ID) L FROM M6 ORDER BY ID;"
both "B8 a materialised sort key"   "SELECT N FROM M6 ORDER BY N DESC, ID;"
both "B9 ORDER BY a column not projected" "SELECT ID FROM M6 ORDER BY N, ID;"
both "B10 UNION set semantics"      "SELECT N FROM M6 UNION SELECT N FROM M6 ORDER BY 1;"
both "B11 PERCENTILE_DISC"          "SELECT PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY N) P FROM M6;"
# LIST: the CONTENT per group, with the blob ID itself normalised away -
# it renders differently and that difference is pinned as a gap below.
noid() { sed 's/0:[0-9a-fA-F]*/0:x/g'; }
check "B12 LIST content per group" \
      "$(crabq "SELECT LIST(ID) L FROM M6 GROUP BY N;" | noid)" \
      "$(engineq "SELECT LIST(ID) L FROM M6 GROUP BY N;" | noid)"

# ---------------------------------------------------------------- C
# AN INDEX ON THE ALTERED COLUMN. The index NAMES candidates and the
# RECORDS decide, so an index-driven read reaches the same projection -
# by a different walk.
both "C1 index probe, scaled literal" "SELECT ID, N FROM IXM WHERE N = 700.00 ORDER BY ID;"
both "C2 index probe, scale-0 literal" "SELECT ID, N FROM IXM WHERE N = 7 ORDER BY ID;"
both "C3 index range scan"          "SELECT ID, N FROM IXM WHERE N > 0 ORDER BY N, ID;"
both "C4 index-driven ORDER BY"     "SELECT ID, N FROM IXM ORDER BY N, ID;"
both "C5 index BETWEEN"             "SELECT ID, N FROM IXM WHERE N BETWEEN 7.00 AND 700.00 ORDER BY ID;"

# ---------------------------------------------------------------- D
# THE NARROWING DIRECTION, and its ROUNDING. `NUMERIC(9,2) -> INTEGER`
# and `-> NUMERIC(18,1)` are both accepted by the engine; the rule these
# rows measure is HALF AWAY FROM ZERO, ties away from zero (8.50 -> 9,
# which banker's rounding would answer 8).
both "D1 narrowing to INTEGER"      "SELECT ID, N FROM NR0 ORDER BY ID;"
both "D2 narrowing to one decimal"  "SELECT ID, N FROM NR1 ORDER BY ID;"
both "D3 narrowing, aggregated"     "SELECT SUM(N) S, MIN(N) MN, MAX(N) MX FROM NR0;"
both "D4 narrowing, DISTINCT"       "SELECT DISTINCT N FROM NR0 ORDER BY 1;"
both "D5 narrowing, grouped"        "SELECT N, COUNT(*) C FROM NR0 GROUP BY N ORDER BY 1;"

# ---------------------------------------------------------------- E
# THE OTHER BACKINGS, AND THE WRITE PATHS. `NUMERIC(20,x)` is INT128, so
# the presented value changes KIND as well as scale; and RETURNING, the
# SET expression, a MERGE key and an AFTER DELETE trigger's OLD each
# reach a decoded row by their own route.
both "E1 Int -> INT128 projection"  "SELECT ID, N FROM MW ORDER BY ID;"
both "E2 Int -> INT128 distinct"    "SELECT DISTINCT N FROM MW ORDER BY 1;"
both "E3 Scaled -> INT128"          "SELECT ID, N FROM M4 ORDER BY ID;"
both "E4 Scaled -> INT128 aggregate" "SELECT SUM(N) S, MIN(N) MN FROM M4;"
both "E5 UPDATE RETURNING OLD/NEW"  "UPDATE M6 SET N = N + 1 WHERE ID = 1 RETURNING OLD.N, NEW.N; ROLLBACK;"
both "E6 DELETE RETURNING"          "DELETE FROM M6 WHERE ID = 1 RETURNING ID, N; ROLLBACK;"
both "E7 the SET expression reads it" "UPDATE M6 SET N = N + 1 WHERE ID = 1; SELECT ID, N FROM M6 ORDER BY ID; ROLLBACK;"
both "E8 AFTER DELETE trigger's OLD" "DELETE FROM TRG WHERE ID = 1; SELECT ID, V FROM LOG ORDER BY ID; ROLLBACK;"
both "E9 AFTER DELETE trigger, control" "DELETE FROM TRG WHERE ID = 3; SELECT ID, V FROM LOG ORDER BY ID; ROLLBACK;"
both "E10 MERGE over a stale key"   "MERGE INTO MG T USING (SELECT 1 K FROM RDB\$DATABASE) S ON T.ID = S.K WHEN MATCHED THEN UPDATE SET N = 5; SELECT ID, N FROM MG ORDER BY ID; ROLLBACK;"
both "E11 a self join on the column" "SELECT A.ID, B.ID FROM M6 A JOIN M6 B ON A.N = B.N ORDER BY A.ID, B.ID;"
both "E12 IN over a subquery"       "SELECT ID FROM M6 WHERE N IN (SELECT N FROM M6 WHERE ID = 1) ORDER BY ID;"
both "E13 the stored data is right" "SELECT COUNT(*) C FROM M6 WHERE N = 700.00;"

# ---------------------------------------------------------------- F
# THE LOGICAL BACKUP. This is the one that survives: the .fbk a client
# restores from. The backup reads each record's bytes at the CURRENT
# format's offsets, so a record older than its relation was read at the
# wrong place - measured, the two pre-ALTER rows of an `INTEGER` ->
# `BIGINT` column restored as `0` and `0`. The oracle is the REAL
# `gbak -c` restoring fire-crab's file, read back BY THE ENGINE.
bk() { # label, table, expected rows
    ran=$((ran + 1))
    rm -f "$D/fc-scalefmt-$2.fbk" "$D/fc-scalefmt-r$2.fdb"
    "$FBSVCMGR" "127.0.0.1/$PORT:service_mgr" user "$U" password "$P" \
        action_backup dbname "$G" bkp_file "$D/fc-scalefmt-$2.fbk" >/dev/null 2>&1
    "$GBAK" -c -user "$U" -pas "$P" "$D/fc-scalefmt-$2.fbk" "$D/fc-scalefmt-r$2.fdb" >/dev/null 2>&1
    chmod 666 "$D/fc-scalefmt-r$2.fdb" 2>/dev/null
    got=$(printf 'SET LIST ON;\nSELECT ID, N FROM %s ORDER BY ID;\n' "$2" \
        | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$D/fc-scalefmt-r$2.fdb" 2>&1 | norm)
    if [ "$got" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     got:  [$got]"; echo "     want: [$3]"; fail=1; fi
}
# W6: INTEGER -> BIGINT, a widening that PRESERVES the scale. This is the
# engine's own answer, asserted as such - the two pre-ALTER rows used to
# restore as 0.
bk "F1 backup of a scale-preserving ALTER" W6 "ID 1|N 700|ID 2|N 7|ID 3|N 7|ID 4|N 700|"
# S6: INTEGER -> NUMERIC(9,2). The MANTISSAS are now the converted ones
# (70000 / 700 / 700 / 70000) rather than a mix of raw and converted, but
# the restored column has lost its SCALE - the recorded att 9 / att 11
# defect. Pinned as the wrong answer it is, with the engine's beside it.
bk "F2 backup of a scale-changing ALTER (RECORDED: the scale is lost)" S6 \
   "ID 1|N 70000|ID 2|N 700|ID 3|N 700|ID 4|N 70000|"
# PL: a plain NUMERIC(9,2) that was NEVER ALTERed loses its scale too -
# which is what makes the defect above independent of any format.
bk "F3 the scale loss is not about formats at all" PL "ID 1|N 70000|"
# ...and what the ENGINE's own backup of the SAME file restores, so the
# two answers sit beside each other in this file.
ran=$((ran + 1))
rm -f "$D/fc-scalefmt-e.fbk" "$D/fc-scalefmt-re.fdb"
"$FBSVCMGR" "127.0.0.1/$REAL:service_mgr" user "$U" password "$P" \
    action_backup dbname "$G" bkp_file "$D/fc-scalefmt-e.fbk" >/dev/null 2>&1
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-scalefmt-e.fbk" "$D/fc-scalefmt-re.fdb" >/dev/null 2>&1
chmod 666 "$D/fc-scalefmt-re.fdb" 2>/dev/null
got=$(printf 'SET LIST ON;\nSELECT ID, N FROM W6 ORDER BY ID;\nSELECT ID, N FROM S6 ORDER BY ID;\nSELECT ID, N FROM PL ORDER BY ID;\n' \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$D/fc-scalefmt-re.fdb" 2>&1 | norm)
want="ID 1|N 700|ID 2|N 7|ID 3|N 7|ID 4|N 700|ID 1|N 700.00|ID 2|N 7.00|ID 3|N 7.00|ID 4|N 700.00|ID 1|N 700.00|"
if [ "$got" = "$want" ]; then echo "OK   F4 the ENGINE's own backup of the same file"; else
    echo "DIFF F4 the ENGINE's own backup of the same file"; echo "     got:  [$got]"; echo "     want: [$want]"; fail=1; fi

# A COLUMN ADDED AFTER THE ROWS: the value lives in the format's DEFAULT
# section, which the backup does not read, so it REFUSES THE WHOLE
# BACKUP rather than laying a zero. That is a new refusal, and what it
# replaces is worse: the backup used to succeed and the real `gbak -c`
# then dropped every pre-ALTER row with `validation error for column
# ... value "*** null ***"` / `warning -- record could not be restored`,
# leaving the restored database two rows short with nothing said. Pinned
# here BOTH ways - the refusal, and the engine restoring all three rows
# from its own backup of the same file.
ran=$((ran + 1))
rm -f "$D/fc-scalefmt-ac.fbk"
"$FBSVCMGR" "127.0.0.1/$PORT:service_mgr" user "$U" password "$P" \
    action_backup dbname "$D/fc-scalefmt-ac.fdb" bkp_file "$D/fc-scalefmt-ac.fbk" >/dev/null 2>&1
if [ ! -s "$D/fc-scalefmt-ac.fbk" ]; then echo "OK   F5 an ADDED column refuses the backup whole"; else
    echo "DIFF F5 an ADDED column refuses the backup whole"
    echo "     got:  [a .fbk was written]"; echo "     want: [no .fbk - the backup refused]"; fail=1; fi
ran=$((ran + 1))
rm -f "$D/fc-scalefmt-ace.fbk" "$D/fc-scalefmt-race.fdb"
"$FBSVCMGR" "127.0.0.1/$REAL:service_mgr" user "$U" password "$P" \
    action_backup dbname "$D/fc-scalefmt-ac.fdb" bkp_file "$D/fc-scalefmt-ace.fbk" >/dev/null 2>&1
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-scalefmt-ace.fbk" "$D/fc-scalefmt-race.fdb" >/dev/null 2>&1
chmod 666 "$D/fc-scalefmt-race.fdb" 2>/dev/null
got=$(printf 'SET LIST ON;\nSELECT ID, N, C, DFT FROM AC ORDER BY ID;\n' \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$D/fc-scalefmt-race.fdb" 2>&1 | norm)
want="ID 1|N 7|C <null>|DFT 99|ID 2|N 8|C <null>|DFT 99|ID 3|N 9|C 5|DFT 4|"
if [ "$got" = "$want" ]; then echo "OK   F6 what the ENGINE's backup of that file restores"; else
    echo "DIFF F6 what the ENGINE's backup of that file restores"
    echo "     got:  [$got]"; echo "     want: [$want]"; fail=1; fi

# ---------------------------------------------------------------- H
# AN INDEX OLDER THAN THE FORMAT THE ROW WAS WRITTEN UNDER - a WRONG
# ANSWER this round did NOT fix, pinned so it cannot move unnoticed.
#
# This section was headed "an index that PREDATES the ALTER" until
# 2026-09-03, and that is NARROWER THAN THE DEFECT. An index entry is
# keyed at the scale the row carried WHEN THE ENTRY WAS MADE, and a
# probe builds ONE key, so an index does not name the rows written under
# any format MINTED AFTER IT. With a single ALTER that reads as "older
# than the ALTER"; with two it does not, and the corrected wording is
# what a reader needs. Measured 2026-09-03 on three fixtures,
# `INTEGER` -> `NUMERIC(9,2)` [-> `NUMERIC(18,4)`], rows written on both
# sides of every ALTER:
#
#   IW   index made BEFORE the only ALTER (this gate's fixture)
#          = 7    crab: ID 2       engine: ID 2, 3
#          = 700  crab: ID 1       engine: ID 1, 4
#          > 0    crab: ID 1, 2    engine: ID 1, 2, 3, 4   <- a RANGE
#          BETWEEN 1 AND 1000: the same two, and the same four
#   IX3  index made AFTER a first ALTER and BEFORE a second
#          = 7    crab: ID 2, 3          engine: ID 2, 3, 5
#          > 0    crab: ID 1, 2, 3, 4    engine: ID 1, 2, 3, 4, 5
#   IX4  index made after BOTH ALTERs: `= 7`, `> 0`, the projection and
#          `ORDER BY` are all the engine's answers, on both servers
#
# IX3 is the shape that corrects the wording: its index is YOUNGER than
# the ALTER, and it still loses the rows written under the format minted
# after it. This fixture carries one ALTER, so only the IW shapes are
# pinned here; IX3 and IX4 are recorded in `docs/roadmap.md`. It is the
# index KEY ENCODING, not the projection - identical on a binary with
# the projection fix reverted - and section C shows the shape does NOT
# appear when the index is younger than every format the table has.
gap "H1 an index older than the format the row was written under, = 7" \
    "SELECT ID FROM IW WHERE N = 7 ORDER BY ID;" \
    "ID 2|" "ID 2|ID 3|"
gap "H2 an index older than the format the row was written under, = 700" \
    "SELECT ID FROM IW WHERE N = 700 ORDER BY ID;" \
    "ID 1|" "ID 1|ID 4|"
# a RANGE probe loses the same rows - added 2026-09-03, because pinning
# only the two equality shapes read as "equality probes only"
gap "H3 ... and a RANGE probe over the same index, > 0" \
    "SELECT ID FROM IW WHERE N > 0 ORDER BY ID;" \
    "ID 1|ID 2|" "ID 1|ID 2|ID 3|ID 4|"
# ...while the same table's PROJECTION, DISTINCT and ORDER BY - which do
# not probe the index - are the engine's, which is this round's fix
both "H4 the same table projects right" "SELECT ID, N FROM IW ORDER BY ID;"
both "H5 the same table's DISTINCT"     "SELECT DISTINCT N FROM IW ORDER BY 1;"
both "H6 the same table's ORDER BY"     "SELECT ID, N FROM IW ORDER BY N, ID;"

# ---------------------------------------------------------------- G
# THE RECORDED RENDERING GAP, both answers pinned.
gap "G1 LIST's blob id" "SELECT LIST(ID) L FROM M6 GROUP BY N;" \
    "L 0:40000001|5|L 0:40000002|2,3|L 0:40000003|1,4|" \
    "L 0:1|5|L 0:3|2,3|L 0:5|1,4|"

echo "scalefmt: $ran checks"
exit $fail
