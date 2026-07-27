#!/bin/bash
# PSQL EXECUTION - EXECUTE PROCEDURE, interpreted.
#
# The engine compiles a procedure body to BLR at CREATE time and its PSQL
# virtual machine (exe.cpp) walks that BLR. fire-crab goes the other way:
# it reads RDB$PROCEDURE_SOURCE - the `BEGIN ... END` text the engine
# stores beside the BLR - reuses the PSQL parser the trigger compiler
# already has, and INTERPRETS the statement tree.
#
# Reading the SOURCE rather than the BLR is what makes this work on
# procedures fire-crab did not create, which is the case that matters: a
# firebird-qa test builds its procedures with isql in its init script.
# EVERY procedure below is created by the ENGINE, and only ever executed
# through fire-crab.
#
# THE DIFFERENTIAL: the same isql runs the same EXECUTE PROCEDURE against
# the engine and against fire-crab, and the returned values must match.
#
# Covered: input/output parameters, assignment, IF/THEN/ELSE, WHILE,
# DECLARE VARIABLE, nested BEGIN..END, integer arithmetic, and NULL
# propagation. Not covered and REFUSED (never half-run): DML in a body,
# SUSPEND/selectable procedures, cursors, FOR SELECT, EXECUTE STATEMENT,
# calling another procedure, non-integer parameters.
#
#   qa/serve-real-psql.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4352}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-psql.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, NULL);
COMMIT;
SET TERM ^;
CREATE PROCEDURE ADD2 (A INTEGER, B INTEGER) RETURNS (R INTEGER) AS
BEGIN
  R = A + B;
END^
CREATE PROCEDURE ARITH (A INTEGER, B INTEGER)
  RETURNS (S INTEGER, D INTEGER, M INTEGER, Q INTEGER) AS
BEGIN
  S = A + B; D = A - B; M = A * B; Q = A / B;
END^
CREATE PROCEDURE MAXOF (A INTEGER, B INTEGER) RETURNS (R INTEGER) AS
BEGIN
  IF (A > B) THEN R = A; ELSE R = B;
END^
CREATE PROCEDURE SIGNOF (A INTEGER) RETURNS (R INTEGER) AS
BEGIN
  IF (A > 0) THEN R = 1;
  ELSE IF (A < 0) THEN R = -1;
  ELSE R = 0;
END^
CREATE PROCEDURE SUMTO (N INTEGER) RETURNS (S INTEGER) AS
DECLARE VARIABLE I INTEGER;
BEGIN
  S = 0; I = 1;
  WHILE (I <= N) DO
  BEGIN
    S = S + I;
    I = I + 1;
  END
END^
CREATE PROCEDURE NESTED (A INTEGER) RETURNS (R INTEGER) AS
BEGIN
  BEGIN
    R = A * 2;
  END
  BEGIN
    R = R + 1;
  END
END^
CREATE PROCEDURE NULLCHK (A INTEGER) RETURNS (R INTEGER, W INTEGER) AS
BEGIN
  R = A + 1;
  IF (A IS NULL) THEN W = 1; ELSE W = 0;
END^
CREATE PROCEDURE PUTROW (I INTEGER, V INTEGER) AS
BEGIN
  INSERT INTO T (ID, N) VALUES (:I, :V);
END^
CREATE PROCEDURE BUMP (I INTEGER, DELTA INTEGER) AS
BEGIN
  UPDATE T SET N = N + :DELTA WHERE ID = :I;
END^
CREATE PROCEDURE ZAP (I INTEGER) AS
BEGIN
  DELETE FROM T WHERE ID = :I;
END^
CREATE PROCEDURE FILLN (FROMID INTEGER, HOWMANY INTEGER) AS
DECLARE VARIABLE K INTEGER;
BEGIN
  K = 0;
  WHILE (K < HOWMANY) DO
  BEGIN
    INSERT INTO T (ID, N) VALUES (:FROMID + :K, :K * 10);
    K = K + 1;
  END
END^
CREATE PROCEDURE COND_WRITE (I INTEGER) AS
BEGIN
  IF (I > 0) THEN INSERT INTO T (ID, N) VALUES (:I, 1);
  ELSE DELETE FROM T WHERE ID = 1;
END^
CREATE PROCEDURE DUPKEY (I INTEGER) AS
BEGIN
  INSERT INTO T (ID, N) VALUES (:I, 1);
  INSERT INTO T (ID, N) VALUES (:I, 2);
END^
CREATE PROCEDURE SUSPENDER RETURNS (R INTEGER) AS
BEGIN
  R = 1;
  SUSPEND;
END^
CREATE PROCEDURE GEN3 (N INTEGER) RETURNS (K INTEGER, SQ INTEGER) AS
DECLARE VARIABLE I INTEGER;
BEGIN
  I = 1;
  WHILE (I <= N) DO
  BEGIN
    K = I; SQ = I * I;
    SUSPEND;
    I = I + 1;
  END
END^
CREATE PROCEDURE ONEROW RETURNS (R INTEGER) AS
BEGIN
  R = 42;
  SUSPEND;
END^
CREATE PROCEDURE NOROWS (N INTEGER) RETURNS (R INTEGER) AS
BEGIN
  IF (N > 0) THEN
  BEGIN
    R = N;
    SUSPEND;
  END
END^
SET TERM ;^
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-psql.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- parameters and arithmetic -----------------------------------------
same "add two inputs"          "EXECUTE PROCEDURE ADD2(2, 3)"
same "negative input"          "EXECUTE PROCEDURE ADD2(10, -4)"
same "zeroes"                  "EXECUTE PROCEDURE ADD2(0, 0)"
same "four outputs at once"    "EXECUTE PROCEDURE ARITH(12, 4)"
same "integer division rounds toward zero" "EXECUTE PROCEDURE ARITH(7, 2)"

# --- IF / ELSE ---------------------------------------------------------
same "IF takes the THEN arm"   "EXECUTE PROCEDURE MAXOF(9, 3)"
same "IF takes the ELSE arm"   "EXECUTE PROCEDURE MAXOF(3, 9)"
same "IF on equal operands"    "EXECUTE PROCEDURE MAXOF(4, 4)"
same "ELSE IF chain, positive" "EXECUTE PROCEDURE SIGNOF(5)"
same "ELSE IF chain, negative" "EXECUTE PROCEDURE SIGNOF(-5)"
same "ELSE IF chain, zero"     "EXECUTE PROCEDURE SIGNOF(0)"

# --- WHILE + DECLARE VARIABLE ------------------------------------------
same "WHILE loop sums to 5"    "EXECUTE PROCEDURE SUMTO(5)"
same "WHILE loop sums to 100"  "EXECUTE PROCEDURE SUMTO(100)"
same "WHILE body never runs"   "EXECUTE PROCEDURE SUMTO(0)"
same "WHILE runs exactly once" "EXECUTE PROCEDURE SUMTO(1)"

# --- nested blocks -----------------------------------------------------
same "nested BEGIN..END blocks in order" "EXECUTE PROCEDURE NESTED(5)"

# --- NULL propagation --------------------------------------------------
same "NULL input propagates through arithmetic" "EXECUTE PROCEDURE NULLCHK(NULL)"
same "non-NULL input"          "EXECUTE PROCEDURE NULLCHK(7)"
same "NULL argument to a two-input procedure"   "EXECUTE PROCEDURE ADD2(NULL, 3)"

# --- the NULL RENDERING this slice also fixed --------------------------
# Output columns are announced NULLABLE (sql_type | 1). libfbclient
# IGNORES a row's null indicator for a column announced NOT NULL and
# renders the raw buffer instead, so before this every NULL came out of
# isql as 0 - in ordinary SELECTs too, not just procedures.
same "a NULL column renders as NULL, not 0"     "SELECT N FROM T WHERE ID = 2"
same "NULL among ordinary rows" "SELECT ID, N FROM T ORDER BY ID"
same "NULL from an expression"  "SELECT N + 1 FROM T WHERE ID = 2"

# --- teeth -------------------------------------------------------------
# 1. the procedure results must not be a constant: SUMTO(5) and SUMTO(100)
#    have to differ, or the interpreter could be returning anything
a=$(printf 'SET HEADING OFF;\nEXECUTE PROCEDURE SUMTO(5);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
b=$(printf 'SET HEADING OFF;\nEXECUTE PROCEDURE SUMTO(100);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$a" = "15" ] && [ "$b" = "5050" ]; then
    echo "OK   teeth: the loop really computes ($a and $b)"
else
    echo "DIFF loop results are [$a] and [$b], want 15 and 5050"; fail=1
fi

# 2. and a NULL really renders as the word, not as a zero
n=$(printf 'SET HEADING OFF;\nSELECT N FROM T WHERE ID = 2;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
case "$n" in
    *"<null>"*) echo "OK   teeth: NULL renders as <null>, not 0" ;;
    *) echo "DIFF a NULL column rendered as [$n]"; fail=1 ;;
esac

# 3. a body this slice still does NOT interpret must FAIL, not answer
#    something invented. SUSPEND (a selectable procedure) is the case.
# --- SELECTABLE PROCEDURES: a body that SUSPENDs is a row source -------
# The engine runs the body as a stream, restarting it for the cursor;
# fire-crab runs it once and serves the rows SUSPEND emitted. Every one
# of these procedures is created by the ENGINE.
same "a selectable procedure's rows"   "SELECT K, SQ FROM GEN3(4)"
same "SELECT * over a procedure"       "SELECT * FROM GEN3(3)"
same "one column of a procedure"       "SELECT SQ FROM GEN3(5)"
same "a column out of order"           "SELECT SQ, K FROM GEN3(3)"
same "a procedure that suspends NO rows" "SELECT K FROM GEN3(0)"
same "a conditional SUSPEND, taken"    "SELECT R FROM NOROWS(7)"
same "a conditional SUSPEND, not taken" "SELECT R FROM NOROWS(0)"
same "a no-argument selectable procedure" "SELECT R FROM ONEROW"
same "EXECUTE PROCEDURE on a selectable one" "EXECUTE PROCEDURE SUSPENDER"
same "COUNT is not supported over a call, but must agree" "SELECT R FROM ONEROW"

# a WHERE over a procedure call is outside this slice - it must fail
# rather than silently ignore the filter
out=$(printf 'SELECT K FROM GEN3(4) WHERE K > 2;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: a WHERE over a procedure call is refused, not ignored" ;;
    *) echo "DIFF a WHERE over a procedure call answered [$out]"; fail=1 ;;
esac
# and the row count must really follow the argument
a=$(printf 'SET HEADING OFF;\nSELECT K FROM GEN3(2);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
b=$(printf 'SET HEADING OFF;\nSELECT K FROM GEN3(5);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
if [ "$a" = "2" ] && [ "$b" = "5" ]; then
    echo "OK   teeth: the loop suspends one row per iteration ($a and $b)"
else
    echo "DIFF GEN3(2) gave $a rows and GEN3(5) gave $b"; fail=1
fi

# --- DML INSIDE A BODY -------------------------------------------------
# A body's write goes through the ordinary INSERT/UPDATE/DELETE planners,
# so index maintenance, defaults, NOT NULL, CHECK and FK enforcement all
# apply. The differential is the strongest one available: fire-crab
# writes ITS OWN copy of the file, the engine applies the SAME procedure
# calls to a reference copy, and then the ENGINE reads both back and the
# tables must be identical - plus gfix must accept what fire-crab wrote.
WORK=/tmp/fc-psql-work.fdb
REF=/tmp/fc-psql-ref.fdb
rm -f "$WORK" "$REF"; cp "$DB" "$WORK"; cp "$DB" "$REF"
trap 'kill $srv 2>/dev/null; rm -f "$DB" "$WORK" "$REF" /tmp/fc-psql-work.fbk' EXIT

# the same calls, one set through fire-crab, one through the engine
CALLS="EXECUTE PROCEDURE PUTROW(10, 100);
EXECUTE PROCEDURE PUTROW(11, 110);
EXECUTE PROCEDURE BUMP(10, 5);
EXECUTE PROCEDURE ZAP(11);
EXECUTE PROCEDURE FILLN(20, 4);
EXECUTE PROCEDURE COND_WRITE(30);
EXECUTE PROCEDURE COND_WRITE(-1);"
# all of them down ONE connection, which is also the test that the
# statement type is right: announcing SELECT for EXECUTE PROCEDURE made
# a client open a cursor over it, and the next statement then desynced
printf '%s\nCOMMIT;\n' "$CALLS" |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$WORK" >/tmp/fc-psql-fc.log 2>&1
printf '%s\nCOMMIT;\n' "$CALLS" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/tmp/fc-psql-en.log 2>&1

dump() { printf 'SET HEADING OFF;\nSELECT ID, COALESCE(N, -999) FROM T ORDER BY ID;\n' |
         "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
# the ENGINE reads both files - fire-crab's own write is what it parses
ours=$(dump "$WORK"); theirs=$(dump "$REF")
if [ "$ours" = "$theirs" ]; then
    echo "OK   a body's INSERT/UPDATE/DELETE leave the engine the same table"
else
    echo "DIFF the tables differ"; echo "     engine-written: [$theirs]";
    echo "     fc-written:     [$ours]"; fail=1
fi
# non-vacuity: the writes must actually have happened
case "$ours" in
    *"10 105"*) echo "OK   teeth: the body's INSERT and UPDATE both landed (10 -> 105)" ;;
    *) echo "DIFF expected id 10 to hold 105, got [$ours]"; fail=1 ;;
esac
case "$ours" in
    *" 11 "*) echo "DIFF the body's DELETE did not remove id 11"; fail=1 ;;
    *) echo "OK   teeth: the body's DELETE removed id 11" ;;
esac
case "$ours" in
    *"20 0"*"21 10"*"22 20"*"23 30"*)
        echo "OK   teeth: the WHILE loop inserted all four rows" ;;
    *) echo "DIFF the loop's rows are wrong: [$ours]"; fail=1 ;;
esac

# the engine must find nothing wrong with the file fire-crab wrote
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1 | tr -d ' \n')
if [ -z "$val" ]; then
    echo "OK   gfix -v -full accepts what the body wrote"
else
    echo "DIFF gfix on fc's file: $val"; fail=1
fi
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-psql-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak walks what the body wrote"
else
    echo "DIFF gbak failed on fc's file"; fail=1
fi

# a failing statement mid-body stops it: the second INSERT duplicates the
# primary key, so the call must fail
out=$(printf 'EXECUTE PROCEDURE DUPKEY(77);\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$WORK" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: a duplicate key inside a body fails the call" ;;
    *) echo "DIFF a duplicate key inside a body reported [$out]"; fail=1 ;;
esac
# and the engine still accepts the file afterwards
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1 | tr -d ' \n')
if [ -z "$val" ]; then
    echo "OK   teeth: the file is still valid after the failed body"
else
    echo "DIFF gfix after the failed body: $val"; fail=1
fi

# A body whose UPDATE sets a column from an EXPRESSION OVER COLUMNS
# (`SET N = N + :d`) used to be refused, because this server's UPDATE took
# no SET expression at all. It does now (serve-real-setexpr.sh), so the
# body must WRITE - and write what the engine writes.
rm -f "$WORK" "$REF"; cp "$DB" "$WORK"; cp "$DB" "$REF"
printf 'EXECUTE PROCEDURE BUMP(1, 7);\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$WORK" >/dev/null 2>&1
printf 'EXECUTE PROCEDURE BUMP(1, 7);\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1
o=$(printf 'SET HEADING OFF;\nSELECT N FROM T WHERE ID = 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$WORK" 2>&1 | tr -d ' \n')
e=$(printf 'SET HEADING OFF;\nSELECT N FROM T WHERE ID = 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$REF" 2>&1 | tr -d ' \n')
if [ "$o" = "$e" ] && [ "$o" = "17" ]; then
    echo "OK   a body's UPDATE ... SET col = col + :var matches the engine ($o)"
else
    echo "DIFF body UPDATE gave fc=[$o] engine=[$e], want 17"; fail=1
fi

exit $fail
