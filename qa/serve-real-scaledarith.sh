#!/bin/bash
# Scaled (NUMERIC) arithmetic inside a PSQL body run through the BLR
# executor. The executor was integer-only ("arithmetic over a non-integer
# value"); now `+`/`-`/`*`/`/`/unary-minus fold exact numerics with the
# engine's dialect-3 scale rules (`+`/`-` align to the finer scale, `*`
# adds scales, `/` scales the dividend), and an assignment COERCES its
# source to the target's declared scale (into an INTEGER slot it rounds
# half-away-from-zero; into a finer NUMERIC it rescales exactly).
#
# Observable through INTEGER-signature routines whose BODIES use a decimal
# literal / NUMERIC arithmetic (the signature is loadable; only the body
# needed scaled math). Both servers run the same queries and the rows are
# compared, and the ENGINE runs the BLR fc stored.
#
# The key correctness pin is FVAR vs FVARC: a NUMERIC(9,2) intermediate
# keeps 3.33 (so *3 = 9.99 -> 10) while an INTEGER intermediate rounds to
# 3 (so *3 = 9) - the assignment coercion, byte-identical to the engine.
#
#   qa/serve-real-scaledarith.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4907}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-scaledarith-crab.fdb"; B="$D/fc-scaledarith-engine.fdb"
LOG="/tmp/fc-serve-scaledarith-$PORT.log"
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
CREATE FUNCTION FMUL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 1.5; END^
CREATE FUNCTION FMULB(A INTEGER) RETURNS BIGINT AS BEGIN RETURN A * 1.5; END^
CREATE FUNCTION FDIV(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3 / 2; END^
CREATE FUNCTION FRND(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A / 2.0; END^
CREATE FUNCTION FNEG(A INTEGER) RETURNS INTEGER AS BEGIN RETURN -(A * 1.5); END^
CREATE FUNCTION FSUB(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A - 0.5; END^
CREATE FUNCTION FVAR(A INTEGER) RETURNS INTEGER AS DECLARE X NUMERIC(9,2); BEGIN X = A / 3.0; RETURN X * 3; END^
CREATE FUNCTION FVARC(A INTEGER) RETURNS INTEGER AS DECLARE X INTEGER; BEGIN X = A / 3.0; RETURN X * 3; END^
CREATE PROCEDURE PMUL(A INTEGER) RETURNS (R INTEGER) AS BEGIN R = A * 2.5; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the routines build on both" "$c" "$e"

cat > "$D/sc.sql" <<'SQL'
SET LIST ON;
SELECT FMUL(5) R FROM RDB$DATABASE;
SELECT FMUL(-5) R FROM RDB$DATABASE;
SELECT FDIV(5) R FROM RDB$DATABASE;
SELECT FRND(5) R FROM RDB$DATABASE;
SELECT FRND(-5) R FROM RDB$DATABASE;
SELECT FNEG(5) R FROM RDB$DATABASE;
SELECT FSUB(3) R FROM RDB$DATABASE;
SELECT FVAR(10) R FROM RDB$DATABASE;
SELECT FVARC(10) R FROM RDB$DATABASE;
SELECT FMULB(5) R FROM RDB$DATABASE;
SELECT R FROM PMUL(5);
SELECT R FROM PMUL(-5);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sc.sql" 2>&1 | norm; }
check "scaled arithmetic + assign coercion answer the engine's value" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# coercion into a too-narrow target raises 22003 "numeric value is out of
# range" (the At-function frame fc omits is stripped); a BIGINT return holds
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d; /-At procedure/d' | tr '\n' '|'; }
cat > "$D/sc2.sql" <<'SQL'
SET LIST ON;
SELECT FMUL(2000000000) R FROM RDB$DATABASE;
SELECT R FROM PMUL(2000000000);
SELECT FMULB(2000000000) R FROM RDB$DATABASE;
SQL
oerr() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/sc2.sql" 2>&1 | enorm; }
check "a NUMERIC value past the INTEGER width raises 22003 (BIGINT holds it)" \
    "$(oerr "127.0.0.1/$PORT:$A")" "$(oerr "127.0.0.1/$REAL:$B")"

# the byte-for-byte BLR proof: the ENGINE runs fc's stored routines
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/sc.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/sc.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored routines identically" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 8"; then echo "OK   FMUL(5)=8 via fc's stored BLR"; else
    echo "DIFF FMUL did not compute: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
