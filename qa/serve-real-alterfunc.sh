#!/bin/bash
# ALTER FUNCTION / CREATE OR ALTER FUNCTION. fc had plan_alter_procedure
# but no function equivalent, so both refused entirely while the engine
# accepts them. plan_alter_function mirrors the procedure planner: it
# rewrites the head to CREATE, compiles via plan_create_function (WITH the
# catalog, so a body function call resolves), and repackages as
# Plan::AlterFunction / CreateOrAlterFunction. The execution drops the
# function and restores it with the SAME RDB$FUNCTION_ID preserved
# (function_id_plain); a CREATE OR ALTER of a new name just creates.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): ALTER an
# existing function then CREATE OR ALTER it, CREATE OR ALTER a NEW one,
# a body that CALLS another function under CREATE OR ALTER, a RECURSIVE
# CREATE OR ALTER, and the byte-exact "ALTER FUNCTION @1 failed / Function
# @1 not found" vector for a missing function.
#
#   qa/serve-real-alterfunc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4941}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-alterfunc-crab.fdb"; B="$D/fc-alterfunc-engine.fdb"
LOG="/tmp/fc-serve-alterfunc-$PORT.log"
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
CREATE FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 2; END^
CREATE FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END^
ALTER FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 100; END^
CREATE OR ALTER FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3; END^
CREATE OR ALTER FUNCTION G(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A - 5; END^
CREATE OR ALTER FUNCTION H(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(A) + 1; END^
CREATE OR ALTER FUNCTION FACT(N INTEGER) RETURNS INTEGER AS BEGIN IF (N <= 1) THEN RETURN 1; RETURN N * FACT(N - 1); END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "ALTER / CREATE OR ALTER FUNCTION build on both" "$c" "$e"

cat > "$D/q-$PORT.sql" <<'SQL'
SET LIST ON;
SELECT F(10) R FROM RDB$DATABASE;
SELECT G(10) R FROM RDB$DATABASE;
SELECT H(4) R FROM RDB$DATABASE;
SELECT FACT(5) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q-$PORT.sql" 2>&1 | norm; }
check "the altered / created-or-altered functions answer" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a plain function and a same-named PACKAGED member coexist; ALTERing the
# plain one must NOT clobber the packaged member's catalog rows (drop_function
# is now package-aware). Probed: fc used to lose PKG.F after ALTER FUNCTION F.
read -r -d '' PKGCO <<'SQL'
SET TERM ^;
CREATE PACKAGE PKC AS BEGIN FUNCTION FC(A INTEGER) RETURNS INTEGER; END^
CREATE PACKAGE BODY PKC AS BEGIN FUNCTION FC(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 100; END END^
CREATE FUNCTION FC(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END^
ALTER FUNCTION FC(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 9; END^
SET TERM ;^
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$PKGCO" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$PKGCO" >/dev/null 2>&1
cat > "$D/co.sql" <<'SQL'
SET LIST ON;
SELECT PKC.FC(2) M FROM RDB$DATABASE;
SELECT FC(2) P FROM RDB$DATABASE;
SQL
coq() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/co.sql" 2>&1 | norm; }
check "ALTER of a plain function keeps a same-named packaged member" \
    "$(coq "127.0.0.1/$PORT:$A")" "$(coq "127.0.0.1/$REAL:$B")"

# the byte-exact not-found vector for ALTER of a missing function
read -r -d '' NF <<'SQL'
SET TERM ^;
ALTER FUNCTION NOPE(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A; END^
SET TERM ;^
SQL
nfe=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$NF" 2>&1 | norm)
nfc=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$NF" 2>&1 | norm)
check "ALTER FUNCTION of a missing name: byte-exact not-found vector" "$nfc" "$nfe"

# the ENGINE runs fc's altered functions
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/q-$PORT.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/q-$PORT.sql" 2>&1 | norm)
check "the ENGINE runs fc's altered functions" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 30"; then echo "OK   F(10)=30 after ALTER+CREATE OR ALTER via fc's file"; else
    echo "DIFF the ALTER did not take: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
