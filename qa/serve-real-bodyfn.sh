#!/bin/bash
# A bare (unqualified) PLAIN user-function call inside a PSQL body -
# `R = DBL(A)`, `RETURN F(A) + 1`. fc refused it: the body's value surface
# knew aggregates, DECLAREd sub-functions, sibling package members and
# built-ins, but not a standalone CREATE FUNCTION. A plain call compiles to
# blr_function (0x64) - counted name, a count byte, the arguments (probed
# from the engine's RDB$FUNCTION_BLR); the exe executor gained blr_function
# (an empty package resolves the plain function, the slot a bare sibling
# takes), dsql binds a bare name against the catalog's plain functions
# (passed from the server via compile_*_with_funcs), and a function's own
# signature is added so a RECURSIVE self-call resolves.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's stored BLR): a
# function and a procedure calling a plain function, a NESTED call
# (DBL(DBL(A))), a multi-arg callee with a call as an argument, a call in
# an IF condition, and a recursive FACT. Arity-mismatch and unknown-name
# both REFUSE on both sides.
#
# Boundaries (recorded):
#  - a body that BOTH calls a plain function AND draws a GENERATOR refuses
#    at CREATE: the call needs the exe executor, exe declines a generator,
#    and the arithmetic-only source interpreter cannot call a function - so
#    fc refuses rather than store BLR it could not itself run. The engine
#    accepts it, a deliberate divergence (a clean refusal, not a
#    create-then-run split). A generator ALONE (no call) is unaffected.
#  - recursion past fc's depth guard (48) refuses where the engine goes
#    ~1000 then raises 54001 - the same stand-in the other slices carry.
#
#   qa/serve-real-bodyfn.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4940}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-bodyfn-crab.fdb"; B="$D/fc-bodyfn-engine.fdb"
LOG="/tmp/fc-serve-bodyfn-$PORT.log"
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
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 2; END^
CREATE FUNCTION ADD3(A INTEGER, B INTEGER, C INTEGER) RETURNS INTEGER AS BEGIN RETURN A + B + C; END^
CREATE FUNCTION FQ(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(A) + 1; END^
CREATE PROCEDURE PQ(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = DBL(A) * 3; SUSPEND; END^
CREATE FUNCTION FNEST(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(DBL(A)); END^
CREATE FUNCTION FMULTI(A INTEGER) RETURNS INTEGER AS BEGIN RETURN ADD3(A, DBL(A), 1); END^
CREATE PROCEDURE PIF(A INTEGER) RETURNS (R INTEGER) AS BEGIN IF (DBL(A) > 5) THEN R = 1; ELSE R = 0; SUSPEND; END^
CREATE FUNCTION FACT(N INTEGER) RETURNS INTEGER AS BEGIN IF (N <= 1) THEN RETURN 1; RETURN N * FACT(N - 1); END^
CREATE PROCEDURE PCOA(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A; SUSPEND; END^
CREATE OR ALTER PROCEDURE PCOA(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = DBL(A) + 1; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | enorm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | enorm)
check "the body-function-call routines build on both" "$c" "$e"

cat > "$D/b.sql" <<'SQL'
SET LIST ON;
SELECT FQ(5) R FROM RDB$DATABASE;
SELECT R FROM PQ(4);
SELECT FNEST(3) R FROM RDB$DATABASE;
SELECT FMULTI(5) R FROM RDB$DATABASE;
SELECT R FROM PIF(4);
SELECT R FROM PIF(1);
SELECT FACT(5) R FROM RDB$DATABASE;
SELECT FACT(8) R FROM RDB$DATABASE;
SELECT R FROM PCOA(4);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/b.sql" 2>&1 | enorm; }
check "call / nested / multi-arg / IF-cond / recursion / CREATE-OR-ALTER, fc runs its own" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# arity mismatch and an unknown name both REFUSE on both sides
aof() { printf 'SET TERM ^;\n%s^\nSET TERM ;^\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$2" 2>&1 | grep -qiE 'error|failed' && echo REFUSE || echo OK; }
ar_e=$(aof "CREATE FUNCTION FBAD(A INT) RETURNS INT AS BEGIN RETURN DBL(1,2); END" "127.0.0.1/$REAL:$B")
ar_c=$(aof "CREATE FUNCTION FBAD(A INT) RETURNS INT AS BEGIN RETURN DBL(1,2); END" "127.0.0.1/$PORT:$A")
check "arity mismatch DBL(1,2) refuses on both" "$ar_c" "$ar_e"
un_e=$(aof "CREATE FUNCTION FUNK(A INT) RETURNS INT AS BEGIN RETURN NOPE(A); END" "127.0.0.1/$REAL:$B")
un_c=$(aof "CREATE FUNCTION FUNK(A INT) RETURNS INT AS BEGIN RETURN NOPE(A); END" "127.0.0.1/$PORT:$A")
check "unknown NOPE(A) refuses on both" "$un_c" "$un_e"

# the ENGINE runs fc's stored blr_function BLR
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/b.sql" <<'SQL'
SET LIST ON;
SELECT FQ(10) R, FNEST(4) R2, FACT(6) R3 FROM RDB$DATABASE;
SELECT R FROM PQ(7);
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/b.sql" 2>&1 | enorm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/b.sql" 2>&1 | enorm)
check "the ENGINE runs fc's stored blr_function BLR" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R3 720"; then echo "OK   FACT(6)=720 via fc's stored blr_function"; else
    echo "DIFF recursion did not run: [$cfile]"; fail=1; fi

# the function-call + generator body refuses at CREATE on fc (a clean
# boundary; the engine accepts it - not compared differentially)
ran=$((ran + 1))
"$FCWIRE" serve "127.0.0.1:$((PORT+1))" "$U" "$P" >/dev/null 2>&1 &
srv2=$!; sleep 0.4
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$((PORT+1)):$A" <<'SQL' >/dev/null 2>&1
SET TERM ^; CREATE SEQUENCE GG^ SET TERM ;^ COMMIT;
SQL
mkfg=$(printf 'SET TERM ^;\nCREATE FUNCTION FGEN(A INT) RETURNS INT AS BEGIN RETURN DBL(A) + GEN_ID(GG,1); END^\nSET TERM ;^\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$((PORT+1)):$A" 2>&1)
kill $srv2 2>/dev/null
if echo "$mkfg" | grep -qiE 'error|failed'; then echo "OK   a call+generator body refuses at CREATE (boundary, no split)"; else
    echo "DIFF a call+generator body was NOT refused: [$mkfg]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
