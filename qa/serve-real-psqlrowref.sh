#!/bin/bash
# AN UNQUALIFIED COLUMN IN A BODY'S NESTED DML IS THAT STATEMENT'S OWN.
#
# A trigger body's statement names columns from two different places.
# `OLD.<col>` and `NEW.<col>` are the row this event fired for; a BARE
# name is a column of the table the nested statement is aimed at, and
# the two have nothing to do with each other even when they are spelled
# the same. `DELETE FROM LG WHERE ID = OLD.ID` reads LG's ID on the left
# and the fired row's ID on the right.
#
# This server ran the body by RENDERING each nested statement back to
# SQL text - folding what it can to a literal so the ordinary planner
# runs it, which is what gives a body's write index maintenance,
# defaults, NOT NULL, CHECK and FK enforcement for free. The fold read
# EVERY field reference from the trigger's row, because `TrigCtx::read`
# was `if context == 1 { new } else { old }` and a bare column's context
# (CTX_PLAIN = 255) is neither. So the bare name was answered with the
# fired row's value and baked into the text as a constant:
#
#   DELETE FROM LG WHERE ID = OLD.ID     ->  DELETE FROM LG WHERE 2 = 2
#   UPDATE LG SET V = V + 1 WHERE ID = OLD.ID
#                                        ->  UPDATE LG SET V = 21 WHERE 2 = 2
#   DELETE FROM LG WHERE V > 1000        ->  DELETE FROM LG WHERE 20 > 1000
#
# The first emptied the log table. The second wrote the FIRED row's
# value + 1 over every row of it. Both are ordinary audit-trigger text,
# both were silent, and neither needs an exotic column type to reach -
# the INTEGER control fails exactly as the DOUBLE one does. Only the
# `INSERT ... VALUES (OLD.x, NEW.y)` shape was safe, which is the shape
# `serve-real-trigdb` covers, so nothing caught it.
#
# EVERY log table below holds SEVERAL rows on purpose. With one row, a
# statement that touches all of them is indistinguishable from one that
# touches the right one, and that is precisely how this survived.
#
#   qa/serve-real-psqlrowref.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4951}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-psqlrowref-crab.fdb"
B="$D/fc-psqlrowref-engine.fdb"
LOG="/tmp/fc-serve-psqlrowref-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T  (ID INTEGER, V INTEGER);
CREATE TABLE LG (ID INTEGER, V INTEGER);
CREATE TABLE U  (ID INTEGER, V INTEGER);
CREATE TABLE LU (ID INTEGER, V INTEGER);
CREATE TABLE W  (ID INTEGER, V INTEGER);
CREATE TABLE LW (ID INTEGER, V INTEGER);
CREATE TABLE X  (ID INTEGER, V INTEGER);
CREATE TABLE LX (ID INTEGER, V INTEGER);
CREATE TABLE Y  (ID INTEGER, V INTEGER);
CREATE TABLE LY (ID INTEGER, V INTEGER);
CREATE TABLE Z  (ID INTEGER, V INTEGER);
CREATE TABLE LZ (ID INTEGER, V INTEGER);
CREATE TABLE PP (ID INTEGER, V INTEGER);
CREATE TABLE AP  (ID INTEGER, D DOUBLE PRECISION, F FLOAT);
CREATE TABLE LAP (ID INTEGER, D DOUBLE PRECISION, F FLOAT);
CREATE TABLE NB  (ID INTEGER, N NUMERIC(38,4));
CREATE TABLE LNB (ID INTEGER, N NUMERIC(38,4));
COMMIT;
INSERT INTO T VALUES (2, 20);
INSERT INTO U VALUES (2, 20);
INSERT INTO W VALUES (2, 20);
INSERT INTO X VALUES (2, 20);
INSERT INTO Y VALUES (2, 20);
INSERT INTO Z VALUES (2, 20);
INSERT INTO LG VALUES (1, 10); INSERT INTO LG VALUES (2, 20); INSERT INTO LG VALUES (3, 30);
INSERT INTO LU VALUES (1, 10); INSERT INTO LU VALUES (2, 20); INSERT INTO LU VALUES (3, 30);
INSERT INTO LW VALUES (1, 10); INSERT INTO LW VALUES (2, 20); INSERT INTO LW VALUES (3, 30);
INSERT INTO LX VALUES (1, 10); INSERT INTO LX VALUES (2, 20); INSERT INTO LX VALUES (3, 30);
INSERT INTO LY VALUES (1, 10); INSERT INTO LY VALUES (2, 20); INSERT INTO LY VALUES (3, 30);
INSERT INTO LZ VALUES (1, 10); INSERT INTO LZ VALUES (2, 20); INSERT INTO LZ VALUES (3, 30);
INSERT INTO PP VALUES (1, 10); INSERT INTO PP VALUES (2, 20); INSERT INTO PP VALUES (3, 30);
INSERT INTO AP VALUES (1, 1.0000000000000002e0, 1.1e0);
INSERT INTO AP VALUES (2, 1e300, 3.4e38);
INSERT INTO LAP VALUES (1, 0, 0); INSERT INTO LAP VALUES (2, 0, 0); INSERT INTO LAP VALUES (9, 42, 42);
INSERT INTO NB VALUES (1, 12.3456);
INSERT INTO LNB VALUES (1, 0); INSERT INTO LNB VALUES (2, 5);
COMMIT;
SET TERM ^ ;
CREATE TRIGGER T_AU FOR T AFTER UPDATE AS
BEGIN DELETE FROM LG WHERE ID = OLD.ID; END^
CREATE TRIGGER U_AU FOR U AFTER UPDATE AS
BEGIN UPDATE LU SET V = V + 1 WHERE ID = OLD.ID; END^
CREATE TRIGGER W_AU FOR W AFTER UPDATE AS
BEGIN UPDATE LW SET V = V + 1; END^
CREATE TRIGGER X_AU FOR X AFTER UPDATE AS
BEGIN DELETE FROM LX WHERE V > 15; END^
CREATE TRIGGER Y_BU FOR Y BEFORE UPDATE AS
BEGIN UPDATE LY SET V = V * 2 WHERE ID = NEW.ID; END^
CREATE TRIGGER Z_AD FOR Z AFTER DELETE AS
BEGIN DELETE FROM LZ WHERE ID = OLD.ID AND V > 5; END^
CREATE PROCEDURE BUMP AS
BEGIN UPDATE PP SET V = V + 1 WHERE ID = 2; END^
CREATE PROCEDURE WIPE AS
BEGIN DELETE FROM PP WHERE V > 25; END^
CREATE TRIGGER AP_AU FOR AP AFTER UPDATE AS
BEGIN UPDATE LAP SET D = NEW.D, F = NEW.F WHERE ID = OLD.ID; END^
CREATE TRIGGER NB_AU FOR NB AFTER UPDATE AS
BEGIN UPDATE LNB SET N = NEW.N WHERE ID = OLD.ID; END^
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
# THE WHERE CLAUSE. A bare column on the left, a row reference on the
# right - the shape that emptied the table.
both "A1 delete by OLD.ID"          "UPDATE T SET V = 99 WHERE ID = 2; SELECT ID, V FROM LG ORDER BY ID; ROLLBACK;"
both "A2 the row count"             "UPDATE T SET V = 99 WHERE ID = 2; SELECT COUNT(*) FROM LG; ROLLBACK;"
both "A3 nothing matches"           "UPDATE T SET V = 99 WHERE ID = 999; SELECT ID, V FROM LG ORDER BY ID; ROLLBACK;"
both "A4 committed after"           "UPDATE T SET V = 99 WHERE ID = 2; COMMIT; SELECT ID, V FROM LG ORDER BY ID;"

# ---------------------------------------------------------------- B
# THE SET LIST. `V + 1` must be each TARGET row's V, not the fired
# row's - the difference between 11 and 21 for LU's first row.
both "B1 update by OLD.ID"          "UPDATE U SET V = 99 WHERE ID = 2; SELECT ID, V FROM LU ORDER BY ID; ROLLBACK;"
both "B2 arithmetic per row"        "UPDATE W SET V = 99 WHERE ID = 2; SELECT ID, V FROM LW ORDER BY ID; ROLLBACK;"
both "B3 unwhered update commits"   "UPDATE W SET V = 99 WHERE ID = 2; COMMIT; SELECT ID, V FROM LW ORDER BY ID;"

# ---------------------------------------------------------------- C
# NO ROW REFERENCE AT ALL. `WHERE V > 15` never mentions the fired row,
# and still read it - the fold does not need an OLD. to go wrong.
both "C1 predicate on own column"   "UPDATE X SET V = 99 WHERE ID = 2; SELECT ID, V FROM LX ORDER BY ID; ROLLBACK;"
both "C2 same, committed"           "UPDATE X SET V = 99 WHERE ID = 2; COMMIT; SELECT ID, V FROM LX ORDER BY ID;"

# ---------------------------------------------------------------- D
# THE OTHER EVENTS. A BEFORE body and a DELETE body reach the same
# renderer.
both "D1 before update, NEW.ID"     "UPDATE Y SET V = 99 WHERE ID = 2; SELECT ID, V FROM LY ORDER BY ID; ROLLBACK;"
both "D2 after delete, OLD.ID"      "DELETE FROM Z WHERE ID = 2; SELECT ID, V FROM LZ ORDER BY ID; ROLLBACK;"
both "D3 after delete, committed"   "DELETE FROM Z WHERE ID = 2; COMMIT; SELECT ID, V FROM LZ ORDER BY ID;"

# ---------------------------------------------------------------- E
# A PROCEDURE BODY has no row at all, so a bare column could only ever
# have meant the target table. It must behave the same.
both "E1 procedure updates one"     "EXECUTE PROCEDURE BUMP; SELECT ID, V FROM PP ORDER BY ID; ROLLBACK;"
both "E2 procedure deletes by own"  "EXECUTE PROCEDURE WIPE; SELECT ID, V FROM PP ORDER BY ID; ROLLBACK;"
both "E3 procedure, committed"      "EXECUTE PROCEDURE BUMP; COMMIT; SELECT ID, V FROM PP ORDER BY ID;"

# ---------------------------------------------------------------- F
# THE SHAPE THAT WAS ALREADY RIGHT stays right: an INSERT whose values
# are row references only. This is what `serve-real-trigdb` pins, and
# it is the regression guard for the fold itself - the fold must still
# happen where it is correct.
both "F1 the audit insert"          "UPDATE T SET V = 99 WHERE ID = 2; SELECT ID, V FROM LG ORDER BY ID; ROLLBACK;"

# ---------------------------------------------------------------- G
# AN APPROXIMATE NUMERIC ROW REFERENCE. The fold spells a DOUBLE and a
# FLOAT in their EXPONENT form - the shortest text that parses back to
# the identical bits - so an audit trigger over a ledger's amounts
# answers instead of refusing. (D - 1) * 1e16 is the check that a value
# one ulp above 1.0 survived; the display form rounds it away.
both "G1 double, one ulp above 1"   "UPDATE AP SET ID = ID WHERE ID = 1; SELECT ID, (D - 1) * 1e16 X, F FROM LAP WHERE ID = 1; ROLLBACK;"
both "G2 double at 1e300, float"    "UPDATE AP SET ID = ID WHERE ID = 2; SELECT ID, D, F FROM LAP WHERE ID = 2; ROLLBACK;"
both "G3 the untouched row"         "UPDATE AP SET ID = ID; SELECT ID, D, F FROM LAP ORDER BY ID; ROLLBACK;"
both "G4 committed"                 "UPDATE AP SET ID = ID; COMMIT; SELECT ID, D, F FROM LAP ORDER BY ID;"

# ---------------------------------------------------------------- H
# A RECORDED BOUNDARY, not a differential: a row reference whose type
# has NO literal form yet - INT128 (NUMERIC over 18 digits), DECFLOAT,
# a blob - refuses the whole statement. The ENGINE ANSWERS these, so
# this is a GAP; what is asserted is that the refusal is CLEAN. It must
# not half-write, and it must not fall back to the bare column name,
# which is what it used to do (`SET N = N`, storing nothing and
# reporting success).
#
# WHEN THE LITERAL LANDS THIS CHECK GOES RED. That is deliberate - it
# is how the boundary gets unrecorded instead of quietly outliving the
# limit that justified it.
c=$(printf 'SET LIST ON;\nUPDATE NB SET ID = ID;\nCOMMIT;\nSELECT ID, N FROM LNB ORDER BY ID;\n' \
    | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "H1 int128 refuses, no write" "$c" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|ID 1|N 0.0000|ID 2|N 5.0000|"

echo "psqlrowref: $ran checks"
exit $fail
