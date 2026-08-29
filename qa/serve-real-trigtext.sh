#!/bin/bash
# A TRIGGER BODY THAT BUILDS A STRING.
#
# Writing a message is the commonest thing a PSQL body does - an audit
# row that says what changed, a log line carrying the key. Every one of
# them refused here, because a body's values were parsed into an
# ARITHMETIC expression grammar (`+ - * /` over integers) and a
# concatenation is not in it. `INSERT INTO LOG VALUES (NEW.ID, 'set to '
# || NEW.A)` was outside the surface, and so was the two-step form that
# builds the string in a variable first.
#
# THE FIX IS NOT A BIGGER EXPRESSION GRAMMAR. A body's own statement is
# rendered back to SQL and run by the ORDINARY planner, which already
# knows the whole value grammar - so when a value will not fit the
# arithmetic form, the VALUES TEXT IS KEPT AS WRITTEN and the frame's
# values are substituted into it (`:var`, `NEW.<col>`, `OLD.<col>`).
# Concatenation comes with everything else the planner can do:
# functions, CASE, CAST.
#
# THE LAW THAT COST A WRONG ANSWER, probed against the engine:
# **trailing blanks belong to a value and not to a statement.** A CHAR
# variable holding a whole statement is padded to its declared width and
# that padding is no part of the SQL (a CHAR(40) holding a SELECT runs)
# - but a CONCATENATION keeps every blank: `'[' || <CHAR(6) 'ab'> ||
# ']'` is `[ab    ]`, not `[ab]`. One renderer served both and trimmed
# for both; it now trims only where the whole value IS the statement.
#
# The RUNNING half is tested over triggers the ENGINE made on both files.
# The COMPILING half is tested at the end: a text body is storable now -
# the shapes were probed against engine-written trigger BLR - so the
# catalog row, the BLR and the debug info are compared byte for byte and
# the ENGINE runs what this server compiled.
#
#   qa/serve-real-trigtext.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4996}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-trigtext-crab.fdb"
B="$D/fc-trigtext-engine.fdb"
LOG="/tmp/fc-serve-trigtext-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/trigtext-$PORT.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER, A INTEGER, C CHAR(6), V VARCHAR(10));
CREATE TABLE U (ID INTEGER, A INTEGER);
CREATE TABLE F (ID INTEGER, A INTEGER, V VARCHAR(10));
CREATE TABLE N (ID INTEGER, V VARCHAR(10));
CREATE TABLE CN (ID INTEGER, A INTEGER, V VARCHAR(10));
CREATE TABLE CW (ID INTEGER);
CREATE TABLE L (ID INTEGER, W VARCHAR(60));
COMMIT;
SET TERM ^ ;
/* 1. the audit line: a literal joined to the row that fired it */
CREATE TRIGGER T_BI FOR T BEFORE INSERT AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEW.ID, 'set to ' || NEW.A);
  INSERT INTO L (ID, W) VALUES (NEW.ID, '[' || NEW.C || ']');
  INSERT INTO L (ID, W) VALUES (NEW.ID, '[' || NEW.V || ']');
END^
/* 2. the two-step form: build it in a variable, then store it */
CREATE TRIGGER U_BI FOR U BEFORE INSERT AS
DECLARE VARIABLE S VARCHAR(60);
BEGIN
  S = 'two-step ' || NEW.A;
  INSERT INTO L (ID, W) VALUES (NEW.ID, :S);
END^
/* 3. an UPDATE body naming both rows */
CREATE TRIGGER U_BU FOR U BEFORE UPDATE AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEW.ID, OLD.A || ' -> ' || NEW.A);
END^
/* 4. everything else the planner can do in a value */
CREATE TRIGGER F_BI FOR F BEFORE INSERT AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEW.ID, UPPER(NEW.V));
  INSERT INTO L (ID, W) VALUES (NEW.ID, CASE WHEN NEW.A > 5 THEN 'big' ELSE 'small' END);
  INSERT INTO L (ID, W) VALUES (NEW.ID, CAST(NEW.A * 2 AS VARCHAR(10)) || '!');
  INSERT INTO L (ID, W) VALUES (NEW.ID, SUBSTRING(NEW.V FROM 1 FOR 3));
END^
/* 6. CONDITIONS the arithmetic grammar cannot hold: a function call, a
      LIKE, an IS NULL over an expression, a comparison of two strings */
CREATE TRIGGER C_BI FOR CN BEFORE INSERT AS
BEGIN
  IF (UPPER(NEW.V) = 'AB') THEN INSERT INTO L (ID, W) VALUES (NEW.ID, 'upper');
  IF (NEW.V LIKE 'a%') THEN INSERT INTO L (ID, W) VALUES (NEW.ID, 'like');
  IF (NEW.V IS NULL) THEN INSERT INTO L (ID, W) VALUES (NEW.ID, 'isnull');
  IF (SUBSTRING(NEW.V FROM 1 FOR 1) = 'a') THEN INSERT INTO L (ID, W) VALUES (NEW.ID, 'substr');
  IF (NEW.V = 'ab' AND NEW.A > 0) THEN INSERT INTO L (ID, W) VALUES (NEW.ID, 'and');
  IF (NEW.V CONTAINING 'B') THEN INSERT INTO L (ID, W) VALUES (NEW.ID, 'containing');
END^
/* ...and a WHILE whose test is one of them */
CREATE TRIGGER CW_BI FOR CW BEFORE INSERT AS
DECLARE VARIABLE I INTEGER;
BEGIN
  I = 0;
  WHILE (CAST(:I AS VARCHAR(4)) <> '3') DO
  BEGIN
    I = I + 1;
    INSERT INTO L (ID, W) VALUES (NEW.ID, 'loop');
  END
END^
/* 5. NULL travels through a concatenation */
CREATE TRIGGER N_BI FOR N BEFORE INSERT AS
BEGIN
  INSERT INTO L (ID, W) VALUES (NEW.ID, 'x' || NEW.V);
END^
SET TERM ; ^
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/trigtext-$PORT.sql" >/dev/null 2>&1
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/trigtext-$PORT.sql"' EXIT
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

# ---- the audit line ----------------------------------------------------
# every row is read back inside <> so a trailing blank is VISIBLE
both "a literal joined to the row that fired it, CHAR padding and all" \
  "INSERT INTO T (ID, A, C, V) VALUES (1, 7, 'xy', 'xy'); COMMIT;
   SELECT ID, '<' || W || '>' AS R FROM L ORDER BY W;"
both "...and an integer column rendered into it" \
  "DELETE FROM L; COMMIT;
   INSERT INTO T (ID, A, C, V) VALUES (2, -3, 'a', 'bcd'); COMMIT;
   SELECT ID, '<' || W || '>' AS R FROM L ORDER BY W;"

# ---- the two-step form, and OLD beside NEW -----------------------------
both "a string built in a variable, then stored" \
  "DELETE FROM L; COMMIT;
   INSERT INTO U (ID, A) VALUES (1, 4); COMMIT;
   SELECT ID, '<' || W || '>' AS R FROM L ORDER BY ID;"
both "an UPDATE body joining OLD to NEW" \
  "DELETE FROM L; COMMIT;
   UPDATE U SET A = 9 WHERE ID = 1; COMMIT;
   SELECT ID, '<' || W || '>' AS R FROM L ORDER BY ID; SELECT ID, A FROM U ORDER BY ID;"

# ---- the rest of the value grammar came with it ------------------------
both "UPPER, CASE, CAST and SUBSTRING in a body's VALUES" \
  "DELETE FROM L; COMMIT;
   INSERT INTO F (ID, A, V) VALUES (1, 9, 'abcdef'); COMMIT;
   SELECT ID, '<' || W || '>' AS R FROM L ORDER BY W;"
both "...and the other branch of the CASE" \
  "DELETE FROM L; COMMIT;
   INSERT INTO F (ID, A, V) VALUES (2, 1, 'zz'); COMMIT;
   SELECT ID, '<' || W || '>' AS R FROM L ORDER BY W;"

# ---- NULL through a concatenation --------------------------------------
both "NULL joined to anything is NULL" \
  "DELETE FROM L; COMMIT;
   INSERT INTO N (ID, V) VALUES (1, NULL);
   INSERT INTO N (ID, V) VALUES (2, 'q'); COMMIT;
   SELECT ID, W, W IS NULL AS ISN FROM L ORDER BY ID;"

# ---- CONDITIONS, the other half of the body grammar --------------------
# an `IF` the arithmetic grammar cannot hold is kept AS WRITTEN too, and
# answered by the planner. Only TRUE takes the branch: a condition that
# is UNKNOWN (a NULL operand) takes the ELSE, which is the engine's own
# three-valued rule.
both "a function call, LIKE, IS NULL, SUBSTRING, AND and CONTAINING in an IF" \
  "DELETE FROM L; COMMIT;
   INSERT INTO CN (ID, A, V) VALUES (1, 5, 'ab'); COMMIT;
   SELECT ID, W FROM L ORDER BY W;"
both "...and the same tests over a NULL, where every one is UNKNOWN" \
  "DELETE FROM L; COMMIT;
   INSERT INTO CN (ID, A, V) VALUES (2, 5, NULL); COMMIT;
   SELECT ID, W FROM L ORDER BY W;"
both "...and over a value that matches none of them" \
  "DELETE FROM L; COMMIT;
   INSERT INTO CN (ID, A, V) VALUES (3, 5, 'zz'); COMMIT;
   SELECT ID, W FROM L ORDER BY W;"
both "a WHILE whose test the planner answers" \
  "DELETE FROM L; COMMIT;
   INSERT INTO CW (ID) VALUES (1); COMMIT;
   SELECT ID, W FROM L ORDER BY ID;"

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT ID, '<' || W || '>' AS R FROM L ORDER BY ID, W; SELECT ID, A FROM U ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- ...AND THIS SERVER COMPILES ONE ------------------------------------
# a text body is STORABLE now: the shapes were probed against
# engine-written trigger BLR - a literal is `blr_literal blr_text2
# <charset u16> <len u16> <bytes>` with charset NONE, a concatenation is
# `blr_concatenate` (39) in prefix form - so the catalog row, the BLR and
# the debug info are compared BYTE FOR BYTE, and then the ENGINE RUNS
# what this server compiled
CA="$D/fc-trigtext-mk-crab.fdb"
CB="$D/fc-trigtext-mk-engine.fdb"
mk_plain() { # <file>
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER, A INTEGER, V VARCHAR(20), C CHAR(6));
CREATE TABLE L (ID INTEGER, W VARCHAR(60));
COMMIT;
SQL
    chmod 666 "$1"
}
mk_plain "$CA"; mk_plain "$CB"
ddl='SET TERM ^ ;
CREATE TRIGGER T_LIT FOR T BEFORE INSERT AS BEGIN INSERT INTO L (ID, W) VALUES (NEW.ID, (a)); END^
CREATE TRIGGER T_CAT FOR T BEFORE INSERT POSITION 3 AS BEGIN INSERT INTO L (ID, W) VALUES (NEW.ID, (b) || NEW.V); END^
CREATE TRIGGER T_CH FOR T BEFORE INSERT POSITION 5 AS BEGIN INSERT INTO L (ID, W) VALUES (NEW.ID, NEW.C || (c) || NEW.V); END^
CREATE TRIGGER T_ASN FOR T BEFORE INSERT POSITION 7 AS
DECLARE VARIABLE S VARCHAR(60);
BEGIN
  S = (d) || NEW.V;
  INSERT INTO L (ID, W) VALUES (NEW.ID, :S);
END^
CREATE TRIGGER T_DCH FOR T BEFORE INSERT POSITION 9 AS
DECLARE VARIABLE C CHAR(5);
BEGIN
  C = (a);
  INSERT INTO L (ID, W) VALUES (NEW.ID, :C);
END^
SET TERM ; ^
COMMIT;'
ddl=$(printf '%s' "$ddl" | sed "s/(a)/'ab'/g; s/(b)/'a'/; s/(c)/'-'/; s/(d)/'two '/")
printf '%s\n' "$ddl" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$CA" >/dev/null 2>&1
printf '%s\n' "$ddl" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$CB" >/dev/null 2>&1
catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | norm
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||TRIM(t.RDB$RELATION_NAME)||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$VALID_BLR
FROM RDB$TRIGGERS t WHERE t.RDB$SYSTEM_FLAG = 0 ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'#'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(400) CHARACTER SET OCTETS)||'#'||CAST(CAST(t.RDB$DEBUG_INFO AS BLOB SUB_TYPE 0) AS VARCHAR(400) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$SYSTEM_FLAG = 0 ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$DEPENDED_ON_NAME)||'|'||COALESCE(TRIM(d.RDB$FIELD_NAME),'-')
FROM RDB$DEPENDENCIES d WHERE d.RDB$DEPENDENT_NAME STARTING WITH 'T_' ORDER BY 1;
SQL
}
check "a TEXT body's row, BLR and debug info are the engine's, byte for byte" \
    "$(catq "$CA")" "$(catq "$CB")"
# ...and the ENGINE runs what this server compiled
for f in "$CA" "$CB"; do
    printf "INSERT INTO T (ID, A, V, C) VALUES (1, 7, 'zz', 'xy'); COMMIT;\n" \
        | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$f" >/dev/null 2>&1
done
ea=$(printf "SET LIST ON; SELECT '<' || W || '>' AS R FROM L ORDER BY W;\n" | "$ISQL" -q -user "$U" -pas "$P" "$CB" 2>&1 | norm)
ca=$(printf "SET LIST ON; SELECT '<' || W || '>' AS R FROM L ORDER BY W;\n" | "$ISQL" -q -user "$U" -pas "$P" "$CA" 2>&1 | norm)
check "the ENGINE runs the text trigger THIS server compiled" "$ca" "$ea"
# A DECLARED TEXT VARIABLE is compiled too, and its shapes were probed
# the same way: `DECLARE VARIABLE S VARCHAR(60)` in a UTF8 database is
# `03 <id u16> 26 0400 F000` - blr_varying2, charset 4, 240 = 60 x 4
# BYTES - and a `CHAR(5)` is `03 <id u16> 0F 0400 1400`, blr_text2 over
# 20. The engine writes ONE dependency row on the CHARACTER SET for a
# body that declares any, whatever the count (object type 17), and the
# comparison above covers it.
rm -f "$CA" "$CB"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
