#!/bin/bash
# DROP / ALTER of a PLAIN routine must not clobber a same-named PACKAGED
# member. A plain function/procedure and a packaged PKG.member of the same
# bare name legally coexist (both live in RDB$FUNCTIONS / RDB$PROCEDURES,
# the plain row's RDB$PACKAGE_NAME NULL, the member's = PKG). drop_function
# / drop_procedure found the plain row package-aware but DELETED (and
# gathered param domains) by NAME ALONE, so DROP or ALTER of the plain
# routine deleted the member's catalog rows as collateral, leaving
# RDB$PACKAGES claiming a member fc had removed. Both dropers are now
# package-aware (plain rows only), and procedure_id / function_id_plain
# resolve the plain id.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): a plain
# F/PP and a packaged PKG.F/PKG.PP; ALTER the plain one then the packaged
# member still answers; DROP the plain one and the member survives.
#
#   qa/serve-real-plainpkgdrop.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4942}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ppdrop-crab.fdb"; B="$D/fc-ppdrop-engine.fdb"
LOG="/tmp/fc-serve-ppdrop-$PORT.log"
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
CREATE PACKAGE PF AS BEGIN FUNCTION F(A INTEGER) RETURNS INTEGER; END^
CREATE PACKAGE BODY PF AS BEGIN FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 100; END END^
CREATE FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END^
CREATE PACKAGE PP AS BEGIN PROCEDURE PR(A INTEGER) RETURNS (R INTEGER); END^
CREATE PACKAGE BODY PP AS BEGIN PROCEDURE PR(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A * 100; SUSPEND; END END^
CREATE PROCEDURE PR(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A + 1; SUSPEND; END^
ALTER FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 2; END^
ALTER PROCEDURE PR(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A + 2; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "plain + packaged coexist; ALTER of the plain ones builds" "$c" "$e"

cat > "$D/q.sql" <<'SQL'
SET LIST ON;
SELECT PF.F(2) M FROM RDB$DATABASE;
SELECT F(2) P FROM RDB$DATABASE;
SELECT R FROM PP.PR(2);
SELECT R FROM PR(2);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q.sql" 2>&1 | norm; }
check "after ALTER: packaged PF.F / PP.PR survive, plain F / PR altered" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# DROP the plain routines; the packaged members must survive
read -r -d '' DROPS <<'SQL'
DROP FUNCTION F;
DROP PROCEDURE PR;
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$DROPS" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$DROPS" >/dev/null 2>&1
cat > "$D/q2.sql" <<'SQL'
SET LIST ON;
SELECT PF.F(3) M FROM RDB$DATABASE;
SELECT R FROM PP.PR(3);
SQL
survive() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q2.sql" 2>&1 | norm; }
check "after DROP of the plain routines, the packaged members survive" \
    "$(survive "127.0.0.1/$PORT:$A")" "$(survive "127.0.0.1/$REAL:$B")"

# the ENGINE reads fc's file with the packaged members intact
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/q2.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/q2.sql" 2>&1 | norm)
check "the ENGINE reads fc's file with the packaged members intact" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "M 300"; then echo "OK   PF.F(3)=300 survived the plain DROP via fc's file"; else
    echo "DIFF the packaged member was clobbered: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
