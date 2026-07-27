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

# 3. an unsupported body must FAIL, not answer something invented. A
#    procedure with DML in it is outside the interpreter.
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<'SQL'
SET TERM ^;
CREATE PROCEDURE HASDML (A INTEGER) RETURNS (R INTEGER) AS
BEGIN
  INSERT INTO T (ID, N) VALUES (:A, :A);
  R = A;
END^
SET TERM ;^
COMMIT;
SQL
out=$(printf 'SET HEADING OFF;\nEXECUTE PROCEDURE HASDML(50);\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: a body with DML is refused, not half-run" ;;
    *) echo "DIFF an unsupported body answered [$out] instead of failing"; fail=1 ;;
esac
# ...and it must not have written the row it refused to run
rows=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T WHERE ID = 50;\n' |
       "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -d ' \n')
if [ "$rows" = "0" ]; then
    echo "OK   teeth: the refused body wrote nothing"
else
    echo "DIFF the refused body left $rows row(s) behind"; fail=1
fi

exit $fail
