#!/bin/bash
# Raising a user EXCEPTION from a FUNCTION body. A procedure body already
# raised a named exception byte-for-byte (the source interpreter builds
# the engine's own vector - number, quoted name, message); a FUNCTION hit
# the same raise but the select-list caller collapsed EVERY error from the
# source path to a generic "Dynamic SQL Error" (EvalErr::Unsupported),
# discarding the ProcErr's status. The caller now surfaces that status, so
# `EXCEPTION E_NEG` from a function raises exactly what it raises from a
# procedure; a genuine "cannot run this body" (status None) stays
# Unsupported. Catching (WHEN ANY) inside a function already worked (it
# happens inside the interpreter, before the result returns).
#
# Covered: a function that raises (numbered per catalog order), a function
# whose inner block CATCHES its own raise via WHEN ANY, a non-raising path,
# and the same functions run by the ENGINE from fc's stored BLR. The
# per-level "At function/procedure" stack frame fc omits is stripped (a
# recorded fc-wide boundary), so enorm drops it on both sides.
#
# Boundary (recorded): the EXCEPTION <name> <message-override> form does
# not COMPILE in fc's dsql yet (refused at CREATE). (WHEN EXCEPTION <name>
# DO handlers DO compile and run - see serve-real-whenexc.)
#
#   qa/serve-real-fnexc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4925}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-fnexc-crab.fdb"; B="$D/fc-fnexc-engine.fdb"
LOG="/tmp/fc-serve-fnexc-$PORT.log"
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
# enorm strips the per-level PSQL stack frame fc omits (At function / At procedure)
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE EXCEPTION E_NEG 'value is negative'^
CREATE EXCEPTION E_BIG 'too big'^
CREATE FUNCTION FCHK(A INTEGER) RETURNS INTEGER AS
BEGIN
  IF (A < 0) THEN EXCEPTION E_NEG;
  IF (A > 100) THEN EXCEPTION E_BIG;
  RETURN A * 2;
END^
CREATE FUNCTION FSELF(A INTEGER) RETURNS INTEGER AS
DECLARE R INTEGER;
BEGIN
  BEGIN
    IF (A < 0) THEN EXCEPTION E_NEG;
    R = A * 2;
  WHEN ANY DO
    R = -1;
  END
  RETURN R;
END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | enorm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | enorm)
check "the exceptions and functions build on both" "$c" "$e"

cat > "$D/x.sql" <<'SQL'
SET LIST ON;
SELECT FCHK(5) R FROM RDB$DATABASE;
SELECT FCHK(-3) R FROM RDB$DATABASE;
SELECT FCHK(200) R FROM RDB$DATABASE;
SELECT FSELF(5) R FROM RDB$DATABASE;
SELECT FSELF(-3) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/x.sql" 2>&1 | enorm; }
check "a function raises E_NEG(1)/E_BIG(2) byte-exact; WHEN ANY catches its own raise" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored BLR (the non-raising and the caught paths
# give a value; the raising path gives the engine's own exception vector)
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/x.sql" <<'SQL'
SET LIST ON;
SELECT FCHK(6) R, FSELF(-9) R2 FROM RDB$DATABASE;
SELECT FCHK(-1) R FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/x.sql" 2>&1 | enorm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/x.sql" 2>&1 | enorm)
check "the ENGINE runs fc's stored exception BLR" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q 'E_NEG'; then echo "OK   E_NEG raised via fc's stored BLR"; else
    echo "DIFF the raise did not surface: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
