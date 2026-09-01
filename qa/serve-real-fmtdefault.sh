#!/bin/bash
# A RECORD MISSING A FIELD CARRIES THAT FORMAT'S STORED DEFAULT.
#
# `ALTER TABLE T ADD B INTEGER DEFAULT 7 NOT NULL` rewrites not one row.
# It cannot: the point of the format machinery is that a schema change
# is O(1). So the value goes INTO the format, and every record still
# stored behind that format reads 7 from there - which is the only
# place a NOT NULL column added to a populated table could get a value
# from.
#
# The format blob says so itself. After `u16 count` and the descriptors
# comes `u16 default_count`, then per default a `u16 field_index`, a
# 12-byte descriptor and that descriptor's worth of value bytes. Read
# off an engine-built database with isql's BLOBDUMP, the whole 46-byte
# format 2 of a two-column MIN1 is:
#
#   0200                          two fields
#   0900 0400 0000 0000 0400 0000   ID  LONG len 4 at offset 4
#   0900 0400 0000 0000 0800 0000   B   LONG len 4 at offset 8
#   0100                          ONE default
#   0100                            for field 1
#   0900 0400 0000 0000 0000 0000   its own descriptor
#   0700 0000                       the value: 7
#
# fire-crab's format parser stopped at the descriptors, with a comment
# claiming the section was ignorable "as are defaults by the engine's
# readers of old rows". That second clause was false, and the cost was:
# every historical row of the table reading NULL for the new column; a
# plain SELECT wrong; INSERT ... SELECT PERSISTING the wrong value; and
# routine `UPDATE T SET <anything else>` answering a false 23000
# "validation error ... value *** null ***" for a NOT NULL column the
# statement never touched.
#
# THE DISCRIMINATING CASE IS THE NULLABLE ONE. `ADD C INTEGER DEFAULT 5`
# writes NO entry into the section (measured on a table carrying both),
# and the engine duly reads NULL for C on the old rows and 5 only on
# rows stored after. So the law is exactly "apply what the section
# lists" - a gate that only checked the NOT NULL column would pass a
# server that materialised every default.
#
#   qa/serve-real-fmtdefault.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4961}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-fmtdefault-crab.fdb"
B="$D/fc-fmtdefault-engine.fdb"
LOG="/tmp/fc-serve-fmtdefault-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER);
CREATE TABLE DR (ID INTEGER, X INTEGER, Y INTEGER);
CREATE TABLE IX (ID INTEGER);
CREATE TABLE CP (ID INTEGER);
CREATE TABLE CPD (ID INTEGER, B INTEGER, S VARCHAR(5));
COMMIT;
INSERT INTO T VALUES (1); INSERT INTO T VALUES (2);
INSERT INTO DR VALUES (1, 100, 200);
INSERT INTO IX VALUES (1); INSERT INTO IX VALUES (2);
INSERT INTO CP VALUES (1); INSERT INTO CP VALUES (2);
COMMIT;
-- every kind of default the section can carry
ALTER TABLE T ADD B INTEGER DEFAULT 7 NOT NULL;
ALTER TABLE T ADD C INTEGER DEFAULT 5;
ALTER TABLE T ADD S VARCHAR(5) DEFAULT 'zz' NOT NULL;
ALTER TABLE T ADD N NUMERIC(9,2) DEFAULT 12.34 NOT NULL;
ALTER TABLE T ADD DT DATE DEFAULT DATE '2001-02-03' NOT NULL;
ALTER TABLE T ADD NODEF INTEGER;
-- a field id is never reused: DROP then ADD leaves a hole
ALTER TABLE DR DROP X;
ALTER TABLE IX ADD K INTEGER DEFAULT 3 NOT NULL;
ALTER TABLE CP ADD B INTEGER DEFAULT 7 NOT NULL;
ALTER TABLE CP ADD S VARCHAR(5) DEFAULT 'zz' NOT NULL;
COMMIT;
ALTER TABLE DR ADD Z INTEGER DEFAULT 9 NOT NULL;
COMMIT;
CREATE INDEX IXK ON IX (K);
COMMIT;
-- ...and a row stored AFTER the ALTER, the control for every check
INSERT INTO T (ID) VALUES (3);
INSERT INTO IX (ID) VALUES (3);
INSERT INTO CP (ID) VALUES (3);
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
# THE PLAIN READ, and the null-vs-value distinction that a bare value
# cannot show: a dropped null indicator prints 0 for an INTEGER, which
# looks like a value until IS NULL and COALESCE disagree with it.
both "A1 the whole row"             "SELECT ID, B, C, S, N, DT, NODEF FROM T ORDER BY ID;"
both "A2 is it really not null"     "SELECT ID, CASE WHEN B IS NULL THEN 'NULL' ELSE 'NOTNULL' END ISN, COALESCE(B,-1) CO, B+1 BP1 FROM T ORDER BY ID;"
both "A3 the NULLABLE default"      "SELECT ID, C, CASE WHEN C IS NULL THEN 'NULL' ELSE 'SET' END ISC FROM T ORDER BY ID;"
both "A4 a column with no default"  "SELECT ID, NODEF, CASE WHEN NODEF IS NULL THEN 'NULL' ELSE 'SET' END FROM T ORDER BY ID;"
both "A5 text, numeric, date"       "SELECT ID, S, CHAR_LENGTH(S) L, N, N*2 N2, DT, EXTRACT(YEAR FROM DT) Y FROM T ORDER BY ID;"
both "A6 dropped column, then add"  "SELECT ID, Y, Z FROM DR ORDER BY ID;"

# ---------------------------------------------------------------- B
# THE DEFAULT IS A VALUE EVERYWHERE A VALUE IS - it must survive into
# predicates, aggregates, ordering and grouping, not just projection.
both "B1 in a predicate"            "SELECT ID FROM T WHERE B = 7 ORDER BY ID;"
both "B2 the negative predicate"    "SELECT COUNT(*) N FROM T WHERE B IS NULL;"
both "B3 aggregated"                "SELECT SUM(B) SB, COUNT(C) CC, MIN(S) MS, MAX(N) MN FROM T;"
both "B4 grouped"                   "SELECT B, COUNT(*) N FROM T GROUP BY B;"
both "B5 ordered by the default"    "SELECT ID FROM T ORDER BY S, ID;"
both "B6 a text predicate"          "SELECT COUNT(*) N FROM T WHERE S = 'zz';"
both "B7 through an index"          "SELECT ID, K FROM IX WHERE K = 3 ORDER BY ID;"
both "B8 index, the count"          "SELECT COUNT(*) N FROM IX WHERE K = 3;"

# ---------------------------------------------------------------- C
# THE WRITE PATHS. An UPDATE that never mentions the column raised a
# false 23000 for it, because the upgraded image carried NULL where the
# format says 7.
both "C1 update another column"     "UPDATE T SET ID = ID + 10 WHERE ID = 1; SELECT ID, B, S FROM T ORDER BY ID; ROLLBACK;"
both "C2 returning old and new"     "UPDATE T SET ID = ID + 10 WHERE ID = 1 RETURNING OLD.B, OLD.S, NEW.B, NEW.S; ROLLBACK;"
both "C3 update the column itself"  "UPDATE T SET B = B + 1 WHERE ID = 1; SELECT ID, B FROM T ORDER BY ID; ROLLBACK;"
both "C4 update every row"          "UPDATE T SET C = B; SELECT ID, B, C FROM T ORDER BY ID; ROLLBACK;"
both "C5 delete returning"          "DELETE FROM T WHERE ID = 2 RETURNING ID, B, S, N; ROLLBACK;"
both "C6 delete by the default"     "DELETE FROM T WHERE B = 7; SELECT ID FROM T ORDER BY ID; ROLLBACK;"
both "C7 committed after update"    "UPDATE T SET ID = ID + 10 WHERE ID = 1; COMMIT; SELECT ID, B, C, S FROM T ORDER BY ID;"

# ---------------------------------------------------------------- D
# THE VALUE MUST NOT BE COPIED, IT MUST BE CONVERTED: a VARCHAR(5)
# field is VARYING len 22 while its default's own descriptor is TEXT
# len 2. An INSERT ... SELECT is where a mis-read default stops being a
# display bug and becomes stored data.
both "D1 insert select persists"    "INSERT INTO CPD (ID, B, S) SELECT ID, B, S FROM CP; SELECT ID, B, S FROM CPD ORDER BY ID; ROLLBACK;"
both "D2 same, committed"           "INSERT INTO CPD (ID, B, S) SELECT ID, B, S FROM CP; COMMIT; SELECT ID, B, S FROM CPD ORDER BY ID;"
both "D3 an expression over it"     "SELECT ID, B * 2 D, S || '!' SS FROM CP ORDER BY ID;"

echo "fmtdefault: $ran checks"
exit $fail
