#!/bin/bash
# DDL TRIGGERS - the third trigger class, and the one a schema is
# POLICED with.
#
# A DDL trigger fires around CREATE / ALTER / DROP: `BEFORE ANY DDL
# STATEMENT` to audit or forbid, `AFTER CREATE TABLE` to react. Its body
# asks WHICH statement fired it through a context namespace of its own -
# `RDB$GET_CONTEXT('DDL_TRIGGER', 'DDL_EVENT' | 'OBJECT_NAME' |
# 'SQL_TEXT')`. This server read these triggers from the catalog and
# IGNORED them, so a database that forbids DROP TABLE let one through.
#
# HOW THE TYPE SAYS WHAT IT IS (jrd/constants.h:362, then measured):
# `RDB$TRIGGER_TYPE >> 13 & 3` is the FAMILY - 0 a relation's DML
# trigger, 1 a database trigger, 2 a DDL trigger - and a DDL trigger's
# type is `TRIGGER_TYPE_DDL | (AFTER ? 1 : 0) | (1 << event)` for EVERY
# event it names, so one trigger may fire for many. `AFTER CREATE TABLE`
# is 16387 = 16384 | 1 | (1 << 1); `BEFORE ANY DDL STATEMENT` is
# 9223372036854767614, every event bit with the family bits and the
# after-bit cleared and the DDL family put back.
#
# THE REFUSAL THAT MATTERS: a DDL statement whose event this server
# cannot NAME, in a file that carries a DDL trigger, refuses rather than
# running unwatched. A trigger that did not fire is a policy that did
# not run, and nothing else would say so.
#
# The triggers are made by the ENGINE on both files - this server does
# not compile a DDL trigger yet (recorded below) - and what is under
# test is FIRING them.
#
#   qa/serve-real-ddltrigger.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4998}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ddltrig-crab.fdb"
B="$D/fc-ddltrig-engine.fdb"
LOG="/tmp/fc-serve-ddltrig-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/ddltrig-$PORT.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE L (ID INTEGER, W VARCHAR(80));
CREATE TABLE KEEP (ID INTEGER, A INTEGER);
CREATE TABLE GOES (ID INTEGER);
CREATE SEQUENCE S;
COMMIT;
SET TERM ^ ;
CREATE EXCEPTION EXD 'that object is protected'^
/* the audit trigger: every DDL statement, before it runs */
CREATE TRIGGER D_ANY BEFORE ANY DDL STATEMENT AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEXT VALUE FOR S,
    'B ' || RDB$GET_CONTEXT('DDL_TRIGGER','DDL_EVENT') || ' ' || RDB$GET_CONTEXT('DDL_TRIGGER','OBJECT_NAME'));
END^
/* ...and one that reacts only to a table appearing */
CREATE TRIGGER D_TAB AFTER CREATE TABLE POSITION 5 AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEXT VALUE FOR S,
    'A CREATE TABLE ' || RDB$GET_CONTEXT('DDL_TRIGGER','OBJECT_NAME'));
END^
/* THE POLICY: no view may be dropped here, ever */
CREATE TRIGGER D_GUARD BEFORE DROP VIEW POSITION 9 AS
BEGIN
  EXCEPTION EXD;
END^
/* ...and a policy whose CONDITION calls a function: this server cannot
   evaluate one in a body condition, so it refuses the whole statement
   rather than skipping the policy (checked as a boundary below) */
CREATE TRIGGER D_COND BEFORE CREATE ROLE POSITION 9 AS
BEGIN
  IF (RDB$GET_CONTEXT('DDL_TRIGGER','OBJECT_NAME') = 'FORBIDDEN') THEN
    EXCEPTION EXD;
END^
SET TERM ; ^
COMMIT;
CREATE TABLE PROTECTED (ID INTEGER);
COMMIT;
DELETE FROM L;
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/ddltrig-$PORT.sql" >/dev/null 2>&1
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/ddltrig-$PORT.sql"' EXIT
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
wipe() {
    for db in "127.0.0.1/$REAL:$B" "127.0.0.1/$PORT:$A"; do
        printf 'DELETE FROM L; COMMIT;\n' | "$ISQL" -q -user "$U" -pas "$P" "$db" >/dev/null 2>&1
    done
}

# ---- the audit line, per verb and object kind --------------------------
wipe
both "CREATE TABLE fires the ANY trigger and the table one" \
  "CREATE TABLE T1 (A INTEGER); COMMIT; SELECT ID, W FROM L ORDER BY ID;"
wipe
both "ALTER TABLE and DROP TABLE name the same object" \
  "ALTER TABLE T1 ADD B INTEGER; COMMIT;
   DROP TABLE T1; COMMIT; SELECT ID, W FROM L ORDER BY ID;"
wipe
both "a SEQUENCE, an EXCEPTION and a DOMAIN" \
  "CREATE SEQUENCE Q1; COMMIT;
   CREATE EXCEPTION E1 'x'; COMMIT;
   CREATE DOMAIN DM1 AS INTEGER; COMMIT;
   SELECT ID, W FROM L ORDER BY ID;"
wipe
both "a VIEW, an INDEX and a PROCEDURE" \
  "CREATE VIEW V1 AS SELECT ID FROM KEEP; COMMIT;
   CREATE INDEX IX1 ON KEEP (A); COMMIT;
   SELECT ID, W FROM L ORDER BY ID;"
wipe
both "...and dropping them again" \
  "DROP INDEX IX1; COMMIT; DROP VIEW V1; COMMIT;
   SELECT ID, W FROM L ORDER BY ID;"

# ---- THE POLICY: a BEFORE body that raises stops the statement ---------
wipe
both "a BEFORE body's raise REFUSES the DDL, with the engine's own vector" \
  "CREATE VIEW VG AS SELECT ID FROM KEEP; COMMIT;
   DROP VIEW VG;
   SELECT COUNT(*) AS STILL FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'VG';"
both "...and the audit rows of the refused statement went with it" \
  "SELECT W FROM L WHERE W LIKE '%DROP VIEW%';"
wipe
both "...while the DROP TABLE it does not guard still runs" \
  "DROP TABLE GOES; COMMIT;
   SELECT ID, W FROM L ORDER BY ID;
   SELECT COUNT(*) AS STILL FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'GOES';"

# ---- SQL_TEXT ----------------------------------------------------------
wipe
# the ENGINE creates it on BOTH files: this server compiles no DDL
# trigger yet, and creating it through fire-crab's own wire would leave
# its file without one - which is a gate testing nothing
for db in "$A" "$B"; do
"$ISQL" -q -user "$U" -pas "$P" "$db" >/dev/null 2>&1 <<'SQL'
SET TERM ^ ;
CREATE TRIGGER D_SQL BEFORE CREATE TABLE POSITION 7 AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEXT VALUE FOR S, 'SQL=' || RDB$GET_CONTEXT('DDL_TRIGGER','SQL_TEXT'));
END^
SET TERM ; ^
COMMIT;
DELETE FROM L; COMMIT;
SQL
done
both "the body reads the statement that fired it" \
  "CREATE TABLE T2 (A INTEGER); COMMIT; SELECT ID, W FROM L ORDER BY ID;"

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT ID, W FROM L ORDER BY ID; SELECT COUNT(*) AS RELS FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG = 0;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

# ---- the boundary: a body CONDITION that calls a function --------------
# `IF (RDB$GET_CONTEXT(...) = 'X')` is outside this server's body
# grammar, so the statement it would police REFUSES - the honest answer,
# because running it unpoliced is the one thing a policy trigger must
# never allow
ran=$((ran + 1))
r=$(printf 'CREATE ROLE R1;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
case "$r" in
    *"Dynamic SQL Error"*) echo "OK   boundary: a policy this server cannot evaluate refuses the statement" ;;
    *) echo "DIFF boundary MOVED: a function call in a body condition"; echo "     [$r]"; fail=1 ;;
esac

# ---- the boundary: this server does not COMPILE one --------------------
ran=$((ran + 1))
r=$(printf "SET TERM ^ ;\nCREATE TRIGGER D_NEW BEFORE ANY DDL STATEMENT AS BEGIN INSERT INTO L (ID) VALUES (1); END^\nSET TERM ; ^\n" \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
case "$r" in
    *"Dynamic SQL Error"*) echo "OK   boundary: this server will not COMPILE a DDL trigger" ;;
    *) echo "DIFF boundary MOVED: compiling a DDL trigger"; echo "     [$r]"; fail=1 ;;
esac
echo "ran $ran checks"
exit $fail
