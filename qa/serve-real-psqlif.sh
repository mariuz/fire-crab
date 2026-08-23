#!/bin/bash
# The IF statement (blr_if) in the exe BLR executor. exe could not convert
# an IF, so a function/procedure body combining IF/ELSE control flow with
# an exe-only feature (a NUMERIC computation, a function call, recursion)
# fell to the source path and refused. exe now runs blr_if: condition,
# then-statement, optional else (a missing else is a bare blr_end); a NULL
# (UNKNOWN) condition takes the else, as the engine does.
#
# This unlocks recursive functions (FACT = IF base case + a sibling call)
# and IF-guarded NUMERIC bodies. Both servers run the same queries and the
# rows are compared, and the ENGINE runs the BLR fc stored.
#
# Boundary (recorded): fc REFUSES a body that recurses past its guard
# (mirroring the source interpreter's psql_depth_guard) where the engine
# handles ~1000-deep recursion and then raises 54001 "Too many concurrent
# executions of the same request" - a deliberate stand-in, not matched here.
#
#   qa/serve-real-psqlif.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4922}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-psqlif-crab.fdb"; B="$D/fc-psqlif-engine.fdb"
LOG="/tmp/fc-serve-psqlif-$PORT.log"
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
CREATE FUNCTION FSIGN(A INTEGER) RETURNS VARCHAR(4) AS BEGIN IF (A > 0) THEN RETURN 'pos'; ELSE RETURN 'neg'; END^
CREATE FUNCTION FABS(A NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN IF (A < 0) THEN RETURN A * -1; RETURN A; END^
CREATE FUNCTION FNC(A INTEGER) RETURNS INTEGER AS BEGIN IF (A > 0) THEN RETURN 1; RETURN 0; END^
CREATE FUNCTION FGRADE(A INTEGER) RETURNS VARCHAR(2) AS BEGIN IF (A >= 90) THEN RETURN 'A'; ELSE IF (A >= 80) THEN RETURN 'B'; ELSE RETURN 'C'; END^
CREATE PACKAGE PK AS BEGIN FUNCTION FACT(N INTEGER) RETURNS INTEGER; END^
CREATE PACKAGE BODY PK AS BEGIN FUNCTION FACT(N INTEGER) RETURNS INTEGER AS BEGIN IF (N <= 1) THEN RETURN 1; RETURN N * FACT(N - 1); END END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the IF-bodied routines build on both" "$c" "$e"

cat > "$D/if.sql" <<'SQL'
SET LIST ON;
SELECT FSIGN(5) R FROM RDB$DATABASE;
SELECT FSIGN(-3) R FROM RDB$DATABASE;
SELECT FABS(-12.50) R FROM RDB$DATABASE;
SELECT FABS(7.25) R FROM RDB$DATABASE;
SELECT FNC(5) R FROM RDB$DATABASE;
SELECT FNC(NULL) R FROM RDB$DATABASE;
SELECT FGRADE(95) R FROM RDB$DATABASE;
SELECT FGRADE(85) R FROM RDB$DATABASE;
SELECT FGRADE(70) R FROM RDB$DATABASE;
SELECT PK.FACT(5) R FROM RDB$DATABASE;
SELECT PK.FACT(1) R FROM RDB$DATABASE;
SELECT PK.FACT(8) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/if.sql" 2>&1 | norm; }
check "IF / ELSE / nested-ELSE / NULL condition / NUMERIC+IF / recursion" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored IF/recursion BLR
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/if.sql" <<'SQL'
SET LIST ON;
SELECT FABS(-9.99) R, PK.FACT(6) R2, FGRADE(88) R3 FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/if.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/if.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored IF/recursion BLR" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R2 720"; then echo "OK   FACT(6)=720 via fc's stored BLR"; else
    echo "DIFF FACT did not compute: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
