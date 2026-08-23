#!/bin/bash
# A user FUNCTION call from inside a PSQL body, run through the exe BLR
# executor - blr_function2. The executor had no function-invoke verb, so a
# body that called another user function (a packaged sibling, or a
# qualified PKG.F from any routine) fell to the source path and refused.
# exe now runs blr_function2: it fetches the callee's BLR (function_blr,
# package-aware) and executes it RECURSIVELY (a depth guard bounds
# runaway recursion), the callee's one output coerced to its return scale.
#
# Covered: a packaged sibling call and a NESTED one (QUAD = DBL(DBL(A))),
# a NUMERIC sibling call (result arithmetic and a param scale mismatch), a
# PLAIN function and a PROCEDURE calling a packaged function. Both servers
# run the same queries; the rows and the describe are compared, and the
# ENGINE runs the BLR fc stored.
#
# Boundary (recorded): a PLAIN function calling another PLAIN function by
# an UNQUALIFIED name (RETURN F(A)) still refuses at CREATE - the dsql
# compiler does not emit a call for a bare unknown name (separate gap).
#
#   qa/serve-real-fncall.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4915}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-fncall-crab.fdb"; B="$D/fc-fncall-engine.fdb"
LOG="/tmp/fc-serve-fncall-$PORT.log"
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

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE PACKAGE PK AS BEGIN
  FUNCTION DBL(A INTEGER) RETURNS INTEGER;
  FUNCTION QUAD(A INTEGER) RETURNS INTEGER;
  FUNCTION NADD(A NUMERIC(9,2)) RETURNS NUMERIC(9,2);
  FUNCTION NCALL(A NUMERIC(9,2)) RETURNS NUMERIC(9,2);
  FUNCTION WIDE(A NUMERIC(18,4)) RETURNS NUMERIC(18,4);
  FUNCTION CALLW(A NUMERIC(9,2)) RETURNS NUMERIC(18,4);
  FUNCTION NARROW(A NUMERIC(9,2)) RETURNS INTEGER;
  FUNCTION FEED(A NUMERIC(18,2)) RETURNS INTEGER;
  FUNCTION TOINT(A INTEGER) RETURNS INTEGER;
  FUNCTION RNDCALL(A NUMERIC(9,2)) RETURNS INTEGER;
  FUNCTION CCAT(A CHAR(3)) RETURNS VARCHAR(10);
  FUNCTION CALLCAT(A VARCHAR(3)) RETURNS VARCHAR(10);
END^
CREATE PACKAGE BODY PK AS BEGIN
  FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 2; END
  FUNCTION QUAD(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(DBL(A)); END
  FUNCTION NADD(A NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN RETURN A + 1; END
  FUNCTION NCALL(A NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN RETURN NADD(A) * 2; END
  FUNCTION WIDE(A NUMERIC(18,4)) RETURNS NUMERIC(18,4) AS BEGIN RETURN A + 0.0001; END
  FUNCTION CALLW(A NUMERIC(9,2)) RETURNS NUMERIC(18,4) AS BEGIN RETURN WIDE(A); END
  FUNCTION NARROW(A NUMERIC(9,2)) RETURNS INTEGER AS BEGIN RETURN 1; END
  FUNCTION FEED(A NUMERIC(18,2)) RETURNS INTEGER AS BEGIN RETURN NARROW(A); END
  FUNCTION TOINT(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A; END
  FUNCTION RNDCALL(A NUMERIC(9,2)) RETURNS INTEGER AS BEGIN RETURN TOINT(A); END
  FUNCTION CCAT(A CHAR(3)) RETURNS VARCHAR(10) AS BEGIN RETURN A || '!'; END
  FUNCTION CALLCAT(A VARCHAR(3)) RETURNS VARCHAR(10) AS BEGIN RETURN CCAT(A); END
END^
CREATE FUNCTION PLAINQ(A INTEGER) RETURNS INTEGER AS BEGIN RETURN PK.DBL(A) + 1; END^
CREATE PROCEDURE PROCQ(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = PK.DBL(A) * 10; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the calling routines build on both" "$c" "$e"

cat > "$D/fc.sql" <<'SQL'
SET LIST ON;
SELECT PK.DBL(5) R FROM RDB$DATABASE;
SELECT PK.QUAD(3) R FROM RDB$DATABASE;
SELECT PK.NADD(10.55) R FROM RDB$DATABASE;
SELECT PK.NCALL(10.00) R FROM RDB$DATABASE;
SELECT PK.CALLW(10.55) R FROM RDB$DATABASE;
SELECT PLAINQ(5) R FROM RDB$DATABASE;
SELECT R FROM PROCQ(5);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/fc.sql" 2>&1 | norm; }
check "sibling / nested / NUMERIC / plain->packaged / proc->packaged calls" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a nested call coerces its argument to the callee's parameter: a NUMERIC
# arg rounds into an INTEGER param, and a value past the param width raises
# 22003 even when the callee never returns the argument (the At-function
# frame fc omits is stripped)
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d' | tr '\n' '|'; }
cat > "$D/fc.sql" <<'SQL'
SET LIST ON;
SELECT PK.RNDCALL(3.7) R FROM RDB$DATABASE;
SELECT PK.FEED(5.50) R FROM RDB$DATABASE;
SELECT PK.FEED(99999999999.99) R FROM RDB$DATABASE;
SELECT PK.CALLCAT('xy') R FROM RDB$DATABASE;
SQL
aof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/fc.sql" 2>&1 | enorm; }
check "a nested call coerces its argument to the callee's parameter (round; 22003 past width)" \
    "$(aof "127.0.0.1/$PORT:$A")" "$(aof "127.0.0.1/$REAL:$B")"

# the describe of a query calling into the routines
cat > "$D/fc.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT PK.QUAD(1), PK.NCALL(1.00), PLAINQ(1) FROM RDB$DATABASE;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/fc.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "function-call describe" "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored BLR (the sibling calls fc compiled)
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/fc.sql" <<'SQL'
SET LIST ON;
SELECT PK.QUAD(3) R, PK.NCALL(10.00) R2, PLAINQ(5) R3 FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/fc.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/fc.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored function-call BLR" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 12"; then echo "OK   QUAD(3)=12 via fc's stored BLR"; else
    echo "DIFF QUAD did not compute: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
