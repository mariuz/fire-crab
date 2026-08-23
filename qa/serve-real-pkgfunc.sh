#!/bin/bash
# A PACKAGED function invoked from a query, run through the exe BLR
# executor. Packaged members used to bypass exe (function_blr skipped any
# package-tagged row, like procedure_blr) and fell to the arithmetic-only
# source interpreter, so a packaged function whose body did scaled
# arithmetic, had a NUMERIC literal/param, or used UPPER/CASE refused.
# function_blr is now package-aware: a dotted name (PKG.F) resolves the
# packaged member's BLR, a bare name resolves the plain function (a plain
# and a packaged member of the same name stay distinct). Packaged
# functions now get the executor's full scalar surface.
#
# Both servers run the same queries; the rows and the describe are
# compared, and the ENGINE runs the BLR fc stored.
#
# Boundary (recorded): a packaged member whose body CALLS A SIBLING
# (blr_function2) still refuses - the executor has no blr_function2, so it
# falls to the source path which cannot run it (a clean refusal, the
# engine answers). Fixing it needs blr_function2 in exe.
#
#   qa/serve-real-pkgfunc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4914}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-pkgfunc-crab.fdb"; B="$D/fc-pkgfunc-engine.fdb"
LOG="/tmp/fc-serve-pkgfunc-$PORT.log"
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
CREATE PACKAGE PKG AS BEGIN
  FUNCTION FADD(A INTEGER, B INTEGER) RETURNS NUMERIC(18,2);
  FUNCTION FMUL(A INTEGER) RETURNS NUMERIC(9,2);
  FUNCTION FCONST RETURNS NUMERIC(9,2);
  FUNCTION FG(A NUMERIC(9,2)) RETURNS NUMERIC(9,2);
  FUNCTION FUP(S VARCHAR(10)) RETURNS VARCHAR(10);
  FUNCTION FCASE(A INTEGER) RETURNS INTEGER;
  FUNCTION DBL(A INTEGER) RETURNS INTEGER;
END^
CREATE PACKAGE BODY PKG AS BEGIN
  FUNCTION FADD(A INTEGER, B INTEGER) RETURNS NUMERIC(18,2) AS BEGIN RETURN A + B; END
  FUNCTION FMUL(A INTEGER) RETURNS NUMERIC(9,2) AS BEGIN RETURN A * 1.5; END
  FUNCTION FCONST RETURNS NUMERIC(9,2) AS BEGIN RETURN 3.14; END
  FUNCTION FG(A NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN RETURN A + 1; END
  FUNCTION FUP(S VARCHAR(10)) RETURNS VARCHAR(10) AS BEGIN RETURN UPPER(S); END
  FUNCTION FCASE(A INTEGER) RETURNS INTEGER AS BEGIN RETURN CASE WHEN A > 0 THEN 10 ELSE 0 END; END
  FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3; END
END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "a plain function and a package build on both" "$c" "$e"

cat > "$D/pf.sql" <<'SQL'
SET LIST ON;
SELECT PKG.FADD(2,3) R FROM RDB$DATABASE;
SELECT PKG.FMUL(5) R FROM RDB$DATABASE;
SELECT PKG.FCONST() R FROM RDB$DATABASE;
SELECT PKG.FG(10.55) R FROM RDB$DATABASE;
SELECT PKG.FUP('hi') R FROM RDB$DATABASE;
SELECT PKG.FCASE(5) R FROM RDB$DATABASE;
SELECT PKG.FCASE(-1) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/pf.sql" 2>&1 | norm; }
check "packaged functions run via exe (numeric, UPPER, CASE, NUMERIC param)" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a plain DBL (A*2) and a packaged PKG.DBL (A*3) resolve to different BLR
cat > "$D/pf.sql" <<'SQL'
SET LIST ON;
SELECT DBL(5) R FROM RDB$DATABASE;
SELECT PKG.DBL(5) R FROM RDB$DATABASE;
SQL
check "a plain and a same-named packaged function resolve distinctly" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the describe of a packaged NUMERIC function call
cat > "$D/pf.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT PKG.FADD(1,1), PKG.FG(1.00) FROM RDB$DATABASE;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/pf.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "packaged NUMERIC function-call describe" "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored packaged functions
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/pf.sql" <<'SQL'
SET LIST ON;
SELECT PKG.FADD(2,3) R, PKG.FMUL(5) R2, PKG.FUP('yo') R3 FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/pf.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/pf.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored packaged functions" "$cfile" "$efile"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
