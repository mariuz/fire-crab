#!/bin/bash
# NUMERIC in a FUNCTION signature - a param and/or a return of type
# NUMERIC(p,s). Previously such a function was -804 ("Function unknown"):
# load_function gated on col_kind = Int/Text only. Now that the exe BLR
# interpreter folds scaled arithmetic (serve-real-scaledarith) a NUMERIC
# function loads, describes from its return descriptor (the exact
# dtype/scale and RDB$FIELD_SUB_TYPE 1), binds a scaled/integer argument
# to the parameter's scale (rescaling, and raising 22003 past the
# parameter's width), computes, and coerces the result to the return.
#
# Both servers run the same queries; the rows, the describe and the
# out-of-range errors are compared, and the ENGINE runs the BLR fc stored.
#
# Boundaries (recorded): NUMERIC(19-38) / INT128 in a signature is a
# separate CREATE FUNCTION DDL gap (fc refuses the create); a DOUBLE /
# approximate signature stays refused (the executor has no f64 arithmetic).
#
#   qa/serve-real-numfunc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4911}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-numfunc-crab.fdb"; B="$D/fc-numfunc-engine.fdb"
LOG="/tmp/fc-serve-numfunc-$PORT.log"
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
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE FUNCTION FN(A NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN RETURN A + 1; END^
CREATE FUNCTION FR(A INTEGER) RETURNS NUMERIC(9,2) AS BEGIN RETURN A * 1.5; END^
CREATE FUNCTION FADD(A NUMERIC(9,2), B NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN RETURN A + B; END^
CREATE FUNCTION FDIV(A NUMERIC(9,2)) RETURNS NUMERIC(18,4) AS BEGIN RETURN A / 3; END^
CREATE FUNCTION FS(A NUMERIC(4,1)) RETURNS NUMERIC(4,1) AS BEGIN RETURN A + 0.5; END^
CREATE FUNCTION FID(A NUMERIC(9,2)) RETURNS NUMERIC(9,2) AS BEGIN RETURN A; END^
CREATE FUNCTION FONE(A NUMERIC(9,2)) RETURNS INTEGER AS BEGIN RETURN 1; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the NUMERIC-signature functions build on both" "$c" "$e"

cat > "$D/nf.sql" <<'SQL'
SET LIST ON;
SELECT FN(10.55) R FROM RDB$DATABASE;
SELECT FR(4) R FROM RDB$DATABASE;
SELECT FADD(10.55, 20.30) R FROM RDB$DATABASE;
SELECT FADD(10.5, 2.25) R FROM RDB$DATABASE;
SELECT FADD(5, 3) R FROM RDB$DATABASE;
SELECT FDIV(10.00) R FROM RDB$DATABASE;
SELECT FS(3.3) R FROM RDB$DATABASE;
SELECT FID(3.999) R FROM RDB$DATABASE;
SELECT FID(100) R FROM RDB$DATABASE;
SELECT FID('3.5') R FROM RDB$DATABASE;
SELECT FID('7') R FROM RDB$DATABASE;
SELECT FN(NULL) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/nf.sql" 2>&1 | norm; }
check "NUMERIC params, returns, cross-type args and rescaling answer the engine" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the describe: the exact dtype/scale and RDB$FIELD_SUB_TYPE 1 (NUMERIC)
cat > "$D/nf.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT FN(1.00), FR(1), FDIV(1.00), FS(1.0) FROM RDB$DATABASE;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/nf.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "NUMERIC function-call describe (dtype, scale, subtype 1)" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# out of range: an argument past the parameter's width, and a result past
# the return's width, both raise 22003 (the At-function frame stripped)
cat > "$D/nf.sql" <<'SQL'
SET LIST ON;
SELECT FONE(999999999.99) R FROM RDB$DATABASE;
SELECT FID(999999999.99) R FROM RDB$DATABASE;
SELECT FID('abc') R FROM RDB$DATABASE;
SQL
oerr() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/nf.sql" 2>&1 | enorm; }
check "an out-of-range NUMERIC argument/result raises 22003" \
    "$(oerr "127.0.0.1/$PORT:$A")" "$(oerr "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored NUMERIC functions
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/nf.sql" <<'SQL'
SET LIST ON;
SELECT FN(10.55) R, FDIV(10.00) R2, FS(3.3) R3 FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/nf.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/nf.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored NUMERIC functions" "$cfile" "$efile"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
