#!/bin/bash
# A re-raise `EXCEPTION;` inside a TRIGGER handler. Triggers already
# raised, caught (WHEN EXCEPTION / WHEN ANY) and stored their BLR, but a
# re-raise refused at CREATE - the server's trigger BLR emitter (NOT dsql;
# triggers go through emit_trigger_stmt) listed Reraise as uninterpretable
# and had no emit for it. It now emits blr_abort,5 (condition 5 = blr_raise,
# the same shape probed for a procedure re-raise), bracketed by the
# savepoint the enclosing handler-bearing block gives every raise.
#
# This server does not itself EXECUTE user-trigger BLR - it refuses DML on
# a table that has a user trigger (writing the row without firing the
# trigger would produce different data) - so the meaningful check is that
# fc COMPILES the trigger exactly as the engine does and stores BLR the
# ENGINE then runs: fc builds the database and trigger, and the engine,
# opening fc's file, fires the trigger on INSERT byte-for-byte like its own.
#
#   qa/serve-real-trigreraise.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4938}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-trigrr-crab.fdb"; B="$D/fc-trigrr-engine.fdb"
LOG="/tmp/fc-serve-trigrr-$PORT.log"
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
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At trigger/d; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE TABLE T (ID INT, V INT)^
CREATE EXCEPTION E_NEG 'value is negative'^
CREATE TRIGGER TG FOR T BEFORE INSERT AS
BEGIN
  BEGIN
    IF (NEW.V < 0) THEN EXCEPTION E_NEG;
  WHEN EXCEPTION E_NEG DO
    EXCEPTION;
  END
END^
SET TERM ;^
COMMIT;
SQL
# fc builds A, the engine builds B - the CREATE must be accepted on both
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | enorm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | enorm)
check "the re-raise trigger builds on both (fc stores the BLR)" "$c" "$e"

# the ENGINE fires the trigger fc stored: a good row inserts, a bad row
# re-raises E_NEG; the row count reflects only the good insert
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/t.sql" <<'SQL'
SET LIST ON;
INSERT INTO T VALUES (1, 5);
INSERT INTO T VALUES (2, -3);
SELECT COUNT(*) C FROM T;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/t.sql" 2>&1 | enorm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/t.sql" 2>&1 | enorm)
check "the ENGINE fires fc's stored re-raise trigger (good inserts, bad re-raises)" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q 'E_NEG' && echo "$cfile" | grep -q 'C 1'; then
    echo "OK   re-raise fired via fc's stored trigger BLR (E_NEG, one row kept)"; else
    echo "DIFF trigger re-raise did not fire as expected: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
