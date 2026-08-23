#!/bin/bash
# A PSQL FUNCTION's body run through the BLR executor - the full scalar
# expression surface a RETURN can carry, not the arithmetic-only source
# path fc used before. UPPER/LOWER, SUBSTRING, CAST, COALESCE, the searched
# CASE, a scalar subquery, string concatenation, an IF branch and a WHILE
# loop all answer the engine's value; a divide-by-zero raises 22012 and a
# bad CAST raises 22018 (the executor's runtime classes surface with the
# engine's own SQLSTATE). Plain functions run via the executor; those it
# cannot run - a packaged member, a body calling a sibling (blr_function2),
# a generator - fall to the source interpreter as before.
#
# Both servers run the same queries; the rows and the error SQLSTATEs are
# compared. (fc omits the engine's `-At function "..." line/col` stack
# frame on a runtime error - a broader fc limitation for executor-path
# errors - so the error compare strips it.)
#
# Boundary (recorded): a PACKAGED function with a rich body, and any
# function that calls another user function, still use the arithmetic-only
# source path (the executor has no blr_function2); those refuse here.
#
#   qa/serve-real-funcbody.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4901}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-funcbody-crab.fdb"; B="$D/fc-funcbody-engine.fdb"
LOG="/tmp/fc-serve-funcbody-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# an error compare that drops the PSQL stack frame fc does not emit
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
CREATE TABLE T (ID INTEGER, S VARCHAR(10));
INSERT INTO T VALUES (1, 'aa'); INSERT INTO T VALUES (2, 'bb'); INSERT INTO T VALUES (3, 'cc');
COMMIT;
SET TERM ^;
CREATE FUNCTION FUP(S VARCHAR(10)) RETURNS VARCHAR(10) AS BEGIN RETURN UPPER(S); END^
CREATE FUNCTION FLO(S VARCHAR(10)) RETURNS VARCHAR(10) AS BEGIN RETURN LOWER(S); END^
CREATE FUNCTION FCASE(A INTEGER) RETURNS INTEGER AS BEGIN RETURN CASE WHEN A > 1 THEN 100 ELSE 0 END; END^
CREATE FUNCTION FSUB(A INTEGER) RETURNS INTEGER AS BEGIN RETURN (SELECT COUNT(*) FROM T WHERE ID <= :A); END^
CREATE FUNCTION FCC(S VARCHAR(5)) RETURNS VARCHAR(20) AS BEGIN RETURN S || '!'; END^
CREATE FUNCTION FCOAL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN COALESCE(A, -1); END^
CREATE FUNCTION FSUBSTR(S VARCHAR(10)) RETURNS VARCHAR(10) AS BEGIN RETURN SUBSTRING(S FROM 1 FOR 2); END^
CREATE FUNCTION FCAST(A INTEGER) RETURNS VARCHAR(20) AS BEGIN RETURN CAST(A AS VARCHAR(20)); END^
CREATE FUNCTION FIF(A INTEGER) RETURNS INTEGER AS DECLARE X INTEGER; BEGIN X = 0; IF (A > 0) THEN X = 1; RETURN X; END^
CREATE FUNCTION FLOOP(N INTEGER) RETURNS INTEGER AS DECLARE I INTEGER; DECLARE S INTEGER; BEGIN S = 0; I = 1; WHILE (I <= N) DO BEGIN S = S + I; I = I + 1; END RETURN S; END^
CREATE FUNCTION FNEST(S VARCHAR(10)) RETURNS VARCHAR(10) AS BEGIN RETURN UPPER(SUBSTRING(S FROM 1 FOR 2)); END^
CREATE FUNCTION FARITH(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3 + 1; END^
CREATE FUNCTION FDIV(A INTEGER, B INTEGER) RETURNS INTEGER AS BEGIN RETURN A / B; END^
CREATE FUNCTION FTN(S VARCHAR(5)) RETURNS INTEGER AS BEGIN RETURN CAST(S AS INTEGER) + 1; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the functions build on both" "$c" "$e"

cat > "$D/fb.sql" <<'SQL'
SET LIST ON;
SELECT FUP('hi') R FROM RDB$DATABASE;
SELECT FLO('HI') R FROM RDB$DATABASE;
SELECT FCASE(5) R FROM RDB$DATABASE;
SELECT FCASE(0) R FROM RDB$DATABASE;
SELECT FSUB(2) R FROM RDB$DATABASE;
SELECT FCC('yo') R FROM RDB$DATABASE;
SELECT FCOAL(NULL) R FROM RDB$DATABASE;
SELECT FCOAL(7) R FROM RDB$DATABASE;
SELECT FSUBSTR('abcdef') R FROM RDB$DATABASE;
SELECT FCAST(42) R FROM RDB$DATABASE;
SELECT FIF(5) R FROM RDB$DATABASE;
SELECT FIF(-1) R FROM RDB$DATABASE;
SELECT FLOOP(4) R FROM RDB$DATABASE;
SELECT FNEST('abcdef') R FROM RDB$DATABASE;
SELECT ID, FARITH(ID) A, FUP(S) U FROM T ORDER BY ID;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/fb.sql" 2>&1 | norm; }
check "the full scalar surface answers the engine's value" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# runtime error parity (SQLSTATE + message; the At-function frame stripped)
cat > "$D/fb.sql" <<'SQL'
SET LIST ON;
SELECT FDIV(10, 0) R FROM RDB$DATABASE;
SELECT FTN('xx') R FROM RDB$DATABASE;
SQL
eerr() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/fb.sql" 2>&1 | enorm; }
check "a divide-by-zero (22012) and a bad CAST (22018) raise the engine's SQLSTATE" \
    "$(eerr "127.0.0.1/$PORT:$A")" "$(eerr "127.0.0.1/$REAL:$B")"

# the describe of a rich function call
cat > "$D/fb.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT FUP('x'), FCASE(1) FROM RDB$DATABASE;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/fb.sql" 2>&1 | grep -iE "sqltype|name:" | norm; }
check "rich function-call describe" "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
