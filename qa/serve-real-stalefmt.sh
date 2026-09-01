#!/bin/bash
# A ROW STORED IN AN OLDER FORMAT THAN ITS TABLE.
#
# `ALTER TABLE T ALTER A TYPE BIGINT` mints a new format and does NOT
# rewrite a single row: every record already on the page keeps its old
# format number and its old byte layout, and the engine re-lays it on
# the way past - reading each field through the record's OWN format and
# MOV_moving it into the new one (jrd/vio.cpp). A table that has ever
# been ALTERed therefore holds rows of two shapes at once, and that is
# the ordinary state of a schema that has been maintained.
#
# This server upgraded the row it was PATCHING and then read the raw
# before-image with the NEWEST descriptors everywhere else - the SET
# expressions' old values, a BEFORE trigger's OLD, the foreign-key
# parent check, RETURNING OLD, an AFTER trigger's OLD and the old index
# key. The offsets fell in the wrong places, so `RETURNING OLD` answered
# 0/0 for a stored 1/7, `SET B = B + 1` read a neighbouring field's
# bytes as an integer, and the patched row went to disk NULL in every
# column: `(NULL, NULL)` committed over `(1, 8)`. Silent, no error, no
# refusal - the worst thing this server can do, one stale ALTER away.
#
# The upgrade also DROPPED any field whose descriptor changed, which is
# the byte-copy law taken one step too far: ALTER TYPE only ever widens,
# so the value converts. Both halves are checked here, and every check
# is paired with the same shape on a row inserted AFTER the ALTER - if a
# control ever diverges the fixture is wrong, not the server.
#
#   qa/serve-real-stalefmt.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4948}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-stalefmt-crab.fdb"
B="$D/fc-stalefmt-engine.fdb"
LOG="/tmp/fc-serve-stalefmt-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T1 (A INTEGER, B INTEGER, C VARCHAR(5));
CREATE TABLE T2 (A INTEGER, B INTEGER);
CREATE TABLE T3 (A INTEGER, B INTEGER);
CREATE TABLE T4 (A INTEGER, B INTEGER);
CREATE TABLE T5 (A INTEGER, B INTEGER);
CREATE TABLE T6 (A INTEGER, B INTEGER, DD INTEGER);
CREATE TABLE T7 (A INTEGER, S VARCHAR(5), N NUMERIC(9,2));
CREATE TABLE PAR (ID INTEGER NOT NULL PRIMARY KEY, TAG INTEGER);
CREATE TABLE CHI (ID INTEGER, PID INTEGER, Z INTEGER);
CREATE EXCEPTION EXOLD 'the AFTER trigger saw OLD.B = 7';
COMMIT;
INSERT INTO T1 VALUES (1, 7, 'ab');
INSERT INTO T1 VALUES (2, 8, NULL);
INSERT INTO T2 VALUES (1, 7);
INSERT INTO T3 VALUES (1, 7);
INSERT INTO T3 VALUES (2, 9);
INSERT INTO T4 VALUES (1, 7);
INSERT INTO T4 VALUES (2, 9);
INSERT INTO T5 VALUES (1, 7);
INSERT INTO T6 VALUES (1, 7, 1936287828);
INSERT INTO T7 VALUES (1, 'abc', 12.34);
INSERT INTO PAR VALUES (1, 100);
INSERT INTO PAR VALUES (2, 200);
INSERT INTO CHI VALUES (1, 1, 5);
COMMIT;
ALTER TABLE T1 ALTER A TYPE BIGINT;
ALTER TABLE T2 ALTER A TYPE BIGINT;
ALTER TABLE T3 ALTER A TYPE BIGINT;
ALTER TABLE T4 ALTER A TYPE BIGINT;
ALTER TABLE T5 ALTER A TYPE BIGINT;
ALTER TABLE T6 DROP DD;
ALTER TABLE T7 ALTER S TYPE VARCHAR(20);
ALTER TABLE T7 ALTER N TYPE NUMERIC(18,2);
ALTER TABLE T7 ADD Q INTEGER DEFAULT 99;
ALTER TABLE CHI ALTER ID TYPE BIGINT;
ALTER TABLE CHI ADD CONSTRAINT FKC FOREIGN KEY (PID) REFERENCES PAR (ID);
COMMIT;
CREATE INDEX T3A ON T3 (A);
COMMIT;
INSERT INTO T1 VALUES (9, 70, 'zz');
INSERT INTO T2 VALUES (9, 70);
INSERT INTO T3 VALUES (9, 70);
INSERT INTO T4 VALUES (9, 70);
INSERT INTO T6 VALUES (9, 70);
INSERT INTO T7 VALUES (9, 'zzz', 56.78, 5);
INSERT INTO CHI VALUES (9, 2, 6);
COMMIT;
SET TERM ^ ;
CREATE TRIGGER T2BU FOR T2 BEFORE UPDATE AS
BEGIN NEW.B = OLD.A * 1000 + OLD.B * 10 + NEW.B; END^
CREATE TRIGGER T2AU FOR T2 AFTER UPDATE AS
BEGIN IF (OLD.B = 7 AND NEW.B = 8) THEN EXCEPTION EXOLD; END^
SET TERM ; ^
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# ---------------------------------------------------------------- A
# THE ROW READS BACK AS ITSELF. Before anything is written: a stale
# record must project the value it was stored with, converted into the
# new descriptor - not NULL, and not the old bytes read at the new
# offsets.
both "A1 stale row projects"        "SELECT A, B, C FROM T1 WHERE B = 7;"
both "A2 stale row control"         "SELECT A, B, C FROM T1 WHERE B = 70;"
both "A3 stale widened varchar"     "SELECT A, S, N FROM T7 WHERE A = 1;"
both "A4 added column is NULL"      "SELECT Q FROM T7 WHERE A = 1;"
both "A5 added column control"      "SELECT Q FROM T7 WHERE A = 9;"
both "A6 dropped column gone"       "SELECT A, B FROM T6 ORDER BY A;"
both "A7 stale row in a predicate"  "SELECT B FROM T1 WHERE A = 1;"
both "A8 stale row aggregated"      "SELECT SUM(A), SUM(B), COUNT(C) FROM T1;"

# ---------------------------------------------------------------- B
# RETURNING OLD AND NEW OVER A STALE ROW. This is where the wrong
# descriptors printed 0/0 for 1/7 and the widened column came back
# NULL. NEW is the patched row, OLD the row as it stood.
both "B1 update returning old/new"  "UPDATE T1 SET B = B + 1 WHERE A = 1 RETURNING OLD.A, OLD.B, OLD.C, NEW.A, NEW.B, NEW.C; ROLLBACK;"
both "B2 control returning"         "UPDATE T1 SET B = B + 1 WHERE A = 9 RETURNING OLD.A, OLD.B, OLD.C, NEW.A, NEW.B, NEW.C; ROLLBACK;"
both "B3 returning old widened"     "UPDATE T7 SET N = N + 1 WHERE A = 1 RETURNING OLD.S, OLD.N, NEW.N, OLD.Q; ROLLBACK;"
both "B4 returning old expression"  "UPDATE T1 SET B = 0 WHERE A = 1 RETURNING OLD.A + OLD.B, OLD.C || 'x'; ROLLBACK;"
both "B5 returning old, all rows"   "UPDATE T1 SET B = B + 1 RETURNING OLD.A, OLD.B, NEW.B; ROLLBACK;"
both "B6 returning old on a NULL"   "UPDATE T1 SET C = 'q' WHERE A = 2 RETURNING OLD.C, NEW.C; ROLLBACK;"

# ---------------------------------------------------------------- C
# THE SET EXPRESSION READS THE OLD ROW. `SET B = B + 1` evaluates B in
# the row as it stands: with the newest offsets over an older image it
# read a neighbouring field's bytes (a dropped VARCHAR's ASCII came
# back as 1936287828 + 1). And the WRITE must land: the committed row
# after the update is the whole point.
both "C1 set reads old value"       "UPDATE T1 SET B = B + 1 WHERE A = 1; SELECT A, B, C FROM T1 WHERE A = 1; ROLLBACK;"
both "C2 set over a dropped col"    "UPDATE T6 SET B = B + 1 WHERE A = 1; SELECT A, B FROM T6 WHERE A = 1; ROLLBACK;"
both "C3 set control"               "UPDATE T6 SET B = B + 1 WHERE A = 9; SELECT A, B FROM T6 WHERE A = 9; ROLLBACK;"
both "C4 two sets see one row"      "UPDATE T1 SET A = B, B = A WHERE B = 7; SELECT A, B FROM T1 WHERE B = 1; ROLLBACK;"
both "C5 set the widened column"    "UPDATE T1 SET A = A + 5 WHERE B = 7; SELECT A, B FROM T1 ORDER BY B; ROLLBACK;"
both "C6 set from a stale varchar"  "UPDATE T7 SET S = S || '!' WHERE A = 1; SELECT S, N, Q FROM T7 WHERE A = 1; ROLLBACK;"
both "C7 set null then read"        "UPDATE T1 SET A = NULL WHERE B = 7; SELECT A, B, C FROM T1 ORDER BY B; ROLLBACK;"

# ---------------------------------------------------------------- D
# THE COMMITTED ROW. The destruction was only visible after the
# commit: RETURNING can be right and the write still wrong.
both "D1 committed after update"    "UPDATE T1 SET B = B + 1 WHERE A = 1; COMMIT; SELECT A, B, C FROM T1 ORDER BY B; ROLLBACK;"
both "D2 committed, second update"  "UPDATE T1 SET B = B + 1 WHERE A = 1; COMMIT; SELECT A, B, C FROM T1 ORDER BY B;"
both "D3 the row is now current"    "UPDATE T1 SET C = 'kk' WHERE A = 1 RETURNING OLD.B, OLD.C, NEW.C; ROLLBACK;"

# ---------------------------------------------------------------- E
# TRIGGERS. A BEFORE body sees OLD and NEW; an AFTER body sees the row
# as it was and as it is. Both read the before-image.
both "E1 BEFORE trigger reads OLD"  "UPDATE T2 SET B = B + 1 WHERE A = 9; SELECT A, B FROM T2 WHERE A = 9; ROLLBACK;"
both "E2 AFTER trigger reads OLD"   "UPDATE T2 SET B = B + 1 WHERE A = 1; ROLLBACK;"
both "E3 AFTER OLD does not fire"   "UPDATE T2 SET B = 5 WHERE A = 9; SELECT A, B FROM T2 ORDER BY A; ROLLBACK;"
both "E4 BEFORE OLD over a stale"   "UPDATE T2 SET B = 100 WHERE A = 1; SELECT A, B FROM T2 WHERE A = 1; ROLLBACK;"
both "E5 the stale row is intact"   "UPDATE T2 SET B = 100 WHERE A = 1; COMMIT; SELECT A, B FROM T2 ORDER BY A;"

# ---------------------------------------------------------------- F
# THE OLD INDEX KEY. An update maintains the index by comparing the
# old key with the new one; a garbled old key leaves the index
# disagreeing with the table.
both "F1 indexed update"            "UPDATE T3 SET A = A + 100 WHERE B = 7; SELECT A, B FROM T3 ORDER BY B; ROLLBACK;"
both "F2 indexed, found by key"     "UPDATE T3 SET A = A + 100 WHERE B = 7; SELECT B FROM T3 WHERE A = 101; ROLLBACK;"
both "F3 old key still absent"      "UPDATE T3 SET A = A + 100 WHERE B = 7; SELECT COUNT(*) FROM T3 WHERE A = 1; ROLLBACK;"
both "F4 indexed control"           "UPDATE T3 SET A = A + 100 WHERE B = 70; SELECT A, B FROM T3 ORDER BY B; ROLLBACK;"
both "F5 update by the index"       "UPDATE T3 SET B = B + 1 WHERE A = 1; SELECT A, B FROM T3 ORDER BY B; ROLLBACK;"

# ---------------------------------------------------------------- G
# DELETE, MERGE and UPDATE OR INSERT reach the same before-image.
both "G1 delete a stale row"        "DELETE FROM T4 WHERE A = 1 RETURNING A, B; SELECT A, B FROM T4 ORDER BY B; ROLLBACK;"
both "G2 delete control"            "DELETE FROM T4 WHERE A = 9 RETURNING A, B; ROLLBACK;"
both "G3 merge updates a stale row" "MERGE INTO T5 T USING (SELECT 1 K FROM RDB\$DATABASE) S ON T.A = S.K WHEN MATCHED THEN UPDATE SET B = T.B + 1; SELECT A, B FROM T5; ROLLBACK;"
both "G4 update or insert"          "UPDATE OR INSERT INTO T5 (A, B) VALUES (1, 55) MATCHING (A) RETURNING B; SELECT A, B FROM T5; ROLLBACK;"

# ---------------------------------------------------------------- H
# THE FOREIGN-KEY PARENT CHECK reads the child's old values too.
both "H1 stale child keeps its key" "UPDATE CHI SET Z = Z + 1 WHERE ID = 1; SELECT ID, PID, Z FROM CHI ORDER BY ID; ROLLBACK;"
both "H2 stale child moves parent"  "UPDATE CHI SET PID = 2 WHERE ID = 1 RETURNING OLD.PID, NEW.PID; ROLLBACK;"
both "H3 stale child to no parent"  "UPDATE CHI SET PID = 77 WHERE ID = 1; ROLLBACK;"
both "H4 parent still referenced"   "DELETE FROM PAR WHERE ID = 1; ROLLBACK;"
both "H5 child control"             "UPDATE CHI SET Z = Z + 1 WHERE ID = 9; SELECT ID, PID, Z FROM CHI ORDER BY ID; ROLLBACK;"

echo "stalefmt: $ran checks"
exit $fail
