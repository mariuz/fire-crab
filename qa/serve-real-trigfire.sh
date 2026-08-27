#!/bin/bash
# FIRING USER TRIGGERS on this server's own DML.
#
# `serve-real-trigger.sh` covers CREATE TRIGGER - the PSQL-to-BLR
# compile and the catalog rows, with the ENGINE executing what this
# server wrote. This gate is the other half: the server RUNS them.
#
# Until now any user trigger on a table made every INSERT, UPDATE and
# DELETE against it REFUSE - writing the row without firing the trigger
# would have stored data the engine decorates (or rejects), which is the
# one thing a converted engine may not do. So a table with an audit or a
# compute-a-column trigger could not be written at all.
#
# What fires now is exactly the surface CREATE TRIGGER already compiles:
# assignments over `NEW.`/`OLD.`, variables, literals and integer
# arithmetic, IF, WHILE, EXCEPTION, and blocks with their WHEN handlers.
# Measured against the engine:
#
#   * a BEFORE trigger COMPUTES a column, and what it assigns to
#     `NEW.<col>` is what gets stored - over a client value too
#   * several triggers fire in POSITION (RDB$TRIGGER_SEQUENCE) order,
#     each seeing what the last one left
#   * a BEFORE UPDATE trigger reads OLD and NEW; a BEFORE DELETE one
#     reads OLD
#   * an EXCEPTION inside a body stops the statement with the ENGINE'S
#     OWN vector, stack item included: `At trigger "PUBLIC"."NAME" line:
#     L, col: C`, whose line and column count the ORIGINAL CREATE
#     TRIGGER text (read back from RDB$DEBUG_INFO)
#   * an AFTER trigger fires with the row written, and its raise still
#     takes the statement back
#   * an INACTIVE trigger does not fire
#
#   * a UNIVERSAL trigger (`BEFORE INSERT OR UPDATE [OR DELETE]`) fires
#     for each of its actions, and its body asks which one with
#     INSERTING / UPDATING / DELETING
#
# Boundaries (recorded): a BEFORE body that touches the database (it
# must decide what is stored, and the statement is holding the working
# copy of the file), a DEFERRED body that names the table it fires for
# (by then that table holds every row the statement wrote), and this
# server's own CREATE TRIGGER for a universal trigger - it RUNS one the
# engine created, it does not yet compile one.
#
#   qa/serve-real-trigfire.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4930}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-trigfire-crab.fdb"
B="$D/fc-trigfire-engine.fdb"
LOG="/tmp/fc-serve-trigfire-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/trigfire.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER, A INTEGER, B INTEGER, C INTEGER);
CREATE TABLE U (ID INTEGER, A INTEGER, B INTEGER);
CREATE TABLE W (ID INTEGER, A INTEGER);
CREATE TABLE M (ID INTEGER, A INTEGER);
CREATE TABLE AUD (ID INTEGER, A INTEGER, KIND VARCHAR(10));
CREATE TABLE V (ID INTEGER, A INTEGER, B INTEGER);
CREATE TABLE D (ID INTEGER, A INTEGER);
COMMIT;
SET TERM ^ ;
CREATE EXCEPTION EX1 'the trigger said no'^
CREATE TRIGGER T_BI FOR T BEFORE INSERT AS BEGIN NEW.B = NEW.A * 2; END^
CREATE TRIGGER T_BI2 FOR T BEFORE INSERT POSITION 5 AS BEGIN IF (NEW.A > 10) THEN NEW.C = 99; ELSE NEW.C = NEW.B + 1; END^
CREATE TRIGGER T_BI3 FOR T BEFORE INSERT POSITION 9 AS BEGIN IF (NEW.A = 7) THEN EXCEPTION EX1; END^
CREATE TRIGGER U_BU FOR U BEFORE UPDATE AS BEGIN NEW.B = OLD.A + NEW.A; END^
CREATE TRIGGER U_AU FOR U AFTER UPDATE AS BEGIN IF (NEW.A = 42) THEN EXCEPTION EX1; END^
CREATE TRIGGER U_BD FOR U BEFORE DELETE AS BEGIN IF (OLD.A = 99) THEN EXCEPTION EX1; END^
CREATE TRIGGER W_BI FOR W BEFORE INSERT AS DECLARE VARIABLE V INTEGER; BEGIN V = 0; WHILE (V < NEW.ID) DO BEGIN V = V + 1; END NEW.A = V * 10; END^
CREATE TRIGGER W_BI2 FOR W BEFORE INSERT POSITION 3 AS BEGIN BEGIN NEW.A = NEW.A / (NEW.ID - 2); WHEN ANY DO NEW.A = -1; END END^
CREATE TRIGGER M_BI FOR M BEFORE INSERT AS BEGIN NEW.A = 1; END^
ALTER TRIGGER M_BI INACTIVE^
CREATE TRIGGER D_AI FOR D AFTER INSERT AS BEGIN INSERT INTO AUD (ID, A, KIND) VALUES (NEW.ID, NEW.A, 'ins'); END^
CREATE TRIGGER D_AU FOR D AFTER UPDATE AS BEGIN INSERT INTO AUD (ID, A, KIND) VALUES (NEW.ID, OLD.A, 'upd'); END^
CREATE TRIGGER D_AD FOR D AFTER DELETE AS BEGIN INSERT INTO AUD (ID, A, KIND) VALUES (OLD.ID, OLD.A, 'del'); END^
CREATE TRIGGER V_BIU FOR V BEFORE INSERT OR UPDATE AS BEGIN IF (INSERTING) THEN NEW.A = 1; ELSE NEW.A = 2; END^
CREATE TRIGGER V_BIUD FOR V BEFORE INSERT OR UPDATE OR DELETE POSITION 4 AS BEGIN IF (DELETING) THEN EXCEPTION EX1; ELSE NEW.B = NEW.A * 10; END^
SET TERM ; ^
COMMIT;
INSERT INTO U VALUES (1, 10, 0);
INSERT INTO U VALUES (2, 20, 0);
INSERT INTO U VALUES (3, 99, 0);
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/trigfire.sql" >/dev/null 2>&1
    chmod 666 "$1"
}
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
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# ---- BEFORE INSERT: computing a column ---------------------------------
both "a BEFORE trigger computes a column, two more in POSITION order" \
  "INSERT INTO T (ID, A) VALUES (1, 3); COMMIT; SELECT ID, A, B, C FROM T WHERE ID = 1;"
both "... the other branch of the second trigger" \
  "INSERT INTO T (ID, A) VALUES (2, 20); COMMIT; SELECT ID, A, B, C FROM T WHERE ID = 2;"
both "a client value the trigger overwrites" \
  "INSERT INTO T (ID, A, B) VALUES (4, 5, 1000); COMMIT; SELECT ID, A, B, C FROM T WHERE ID = 4;"
both "an EXCEPTION in a trigger stops the statement, with the engine's stack item" \
  "INSERT INTO T (ID, A) VALUES (3, 7); COMMIT; SELECT COUNT(*) FROM T;"
both "a WHILE loop and a local variable" \
  "INSERT INTO W (ID) VALUES (4); COMMIT; SELECT ID, A FROM W WHERE ID = 4;"
both "a WHEN handler inside the body catches the raise" \
  "INSERT INTO W (ID) VALUES (2); COMMIT; SELECT ID, A FROM W WHERE ID = 2;"
both "an INACTIVE trigger does not fire" \
  "INSERT INTO M (ID, A) VALUES (1, 7); COMMIT; SELECT ID, A FROM M;"

# ---- UPDATE and DELETE --------------------------------------------------
both "a BEFORE UPDATE trigger reads OLD and NEW" \
  "UPDATE U SET A = 5 WHERE ID = 1; COMMIT; SELECT ID, A, B FROM U WHERE ID = 1;"
both "an AFTER UPDATE raise takes the row back" \
  "UPDATE U SET A = 42 WHERE ID = 2; COMMIT; SELECT ID, A, B FROM U WHERE ID = 2;"
both "a BEFORE DELETE trigger reads OLD and refuses the row" \
  "DELETE FROM U WHERE ID = 3; COMMIT; SELECT COUNT(*) FROM U;"
both "... and the DELETE it allows" \
  "DELETE FROM U WHERE ID = 2; COMMIT; SELECT ID FROM U ORDER BY ID;"
both "an UPDATE that touches several rows fires per row" \
  "UPDATE U SET A = A + 1; COMMIT; SELECT ID, A, B FROM U ORDER BY ID;"

# ---- a UNIVERSAL trigger: one body, several actions ---------------------
# The type packs up to three actions, and the body asks which one fired
# it with INSERTING / UPDATING / DELETING.
both "a universal trigger fires for the INSERT, and INSERTING answers" \
  "INSERT INTO V (ID) VALUES (1); COMMIT; SELECT ID, A, B FROM V ORDER BY ID;"
both "... and for the UPDATE, where UPDATING does" \
  "UPDATE V SET ID = 1 WHERE ID = 1; COMMIT; SELECT ID, A, B FROM V ORDER BY ID;"
both "... and the DELETE branch raises" \
  "DELETE FROM V WHERE ID = 1; COMMIT; SELECT COUNT(*) FROM V;"

# ---- an AFTER trigger that WRITES another table -------------------------
# Its body touches the database, which the statement is holding the
# working copy of - so it runs DEFERRED: after the statement's own
# writes are applied, inside the same undo window.
both "an AFTER INSERT trigger writes the audit row" \
  "INSERT INTO D (ID, A) VALUES (1, 10); COMMIT; SELECT ID, A FROM D ORDER BY ID; SELECT ID, A, KIND FROM AUD ORDER BY ID, KIND;"
both "an AFTER UPDATE trigger sees OLD and NEW" \
  "UPDATE D SET A = 11 WHERE ID = 1; COMMIT; SELECT ID, A FROM D ORDER BY ID; SELECT ID, A, KIND FROM AUD ORDER BY ID, KIND;"
both "an AFTER DELETE trigger reads the row that went" \
  "DELETE FROM D WHERE ID = 1; COMMIT; SELECT COUNT(*) FROM D; SELECT ID, A, KIND FROM AUD ORDER BY ID, KIND;"
both "a multi-row INSERT ... SELECT fires it once per row" \
  "DELETE FROM AUD; INSERT INTO D (ID, A) VALUES (5, 50); INSERT INTO D (ID, A) VALUES (6, 60); COMMIT; SELECT ID, A, KIND FROM AUD ORDER BY ID;"

# ---- the engine reads what fire-crab wrote ------------------------------
eng_q="SET LIST ON; SELECT ID, A, B, C FROM T ORDER BY ID; SELECT ID, A, B FROM U ORDER BY ID; SELECT ID, A FROM W ORDER BY ID; SELECT ID, A, KIND FROM AUD ORDER BY ID, KIND; SELECT ID, A, B FROM V ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     [$r]"; fail=1 ;;
    esac
}
# a trigger whose body WRITES another table: the statement holds the
# working copy of the file, and a nested write would be lost under it
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1 <<'SQL'
CREATE TABLE LOGT (ID INTEGER, W VARCHAR(20));
COMMIT;
SET TERM ^ ;
CREATE TRIGGER T_BLOG FOR T BEFORE INSERT POSITION 12 AS BEGIN INSERT INTO LOGT (ID, W) VALUES (NEW.ID, 'ins'); END^
SET TERM ; ^
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "$A" >/dev/null 2>&1 <<'SQL'
CREATE TABLE LOGT (ID INTEGER, W VARCHAR(20));
COMMIT;
SET TERM ^ ;
CREATE TRIGGER T_BLOG FOR T BEFORE INSERT POSITION 12 AS BEGIN INSERT INTO LOGT (ID, W) VALUES (NEW.ID, 'ins'); END^
CREATE TRIGGER T_MULTI FOR M BEFORE INSERT OR UPDATE AS BEGIN INSERT INTO LOGT (ID, W) VALUES (NEW.ID, 'm'); END^
CREATE TRIGGER D_ASELF FOR D AFTER INSERT POSITION 7 AS BEGIN UPDATE D SET A = A WHERE ID = NEW.ID; END^
SET TERM ; ^
COMMIT;
SQL
refuses "a BEFORE trigger that writes another table refuses (it must decide the row)" \
  "INSERT INTO T (ID, A) VALUES (30, 1);"
refuses "a deferred AFTER trigger that names ITS OWN table refuses" \
  "INSERT INTO D (ID, A) VALUES (30, 1);"
refuses "a universal trigger whose BEFORE body writes another table refuses too" \
  "INSERT INTO M (ID, A) VALUES (30, 1);"
# fire-crab RUNS a universal trigger the engine created; its own CREATE
# TRIGGER still refuses to compile one (recorded - the composed type and
# the action predicates have no probed BLR here yet)
refuses "CREATE TRIGGER for a universal trigger still refuses" \
  "CREATE TRIGGER V_X FOR V BEFORE INSERT OR UPDATE AS BEGIN NEW.A = 1; END;"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
