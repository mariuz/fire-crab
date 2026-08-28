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
# Boundaries: this server cannot COMPILE such a body to BLR - it has no
# probed byte shape for a text expression - so CREATE TRIGGER refuses to
# STORE one, exactly as it already refused a body carrying a text
# literal. The triggers here are made by the ENGINE on both files; what
# is under test is RUNNING them.
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

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT ID, '<' || W || '>' AS R FROM L ORDER BY ID, W; SELECT ID, A FROM U ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- the boundary: such a body cannot be STORED ------------------------
ran=$((ran + 1))
r=$(printf "SET TERM ^ ;\nCREATE TRIGGER T_TXT FOR T BEFORE INSERT POSITION 9 AS BEGIN INSERT INTO L (ID, W) VALUES (NEW.ID, 'a' || NEW.A); END^\nSET TERM ; ^\n" \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
case "$r" in
    *"Dynamic SQL Error"*) echo "OK   boundary: this server will not COMPILE a text body to BLR" ;;
    *) echo "DIFF boundary MOVED: compiling a text body"; echo "     [$r]"; fail=1 ;;
esac
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
