#!/bin/bash
# A bare `EXCEPTION;` inside a WHEN handler - RE-RAISE the caught
# exception with its identity intact (the client sees the ORIGINAL
# exception, not a new one). The source interpreter already ran it
# (TrigStmt::Reraise re-throws what the handler caught), but the dsql
# COMPILER required a name after EXCEPTION and refused a bare one, so
# CREATE failed. Probed from the engine's stored BLR, a re-raise is
# `blr_abort, 5` (condition 5 = blr_raise, no name) where a named raise
# is `blr_abort, 2, <len>, <name>`; dsql now emits it, and the ENGINE
# runs the BLR fc stored.
#
# Covered (fc vs the live engine, byte-for-byte, and the ENGINE re-runs
# fc's BLR): a procedure that catches, does cleanup in a BEGIN block and
# re-raises; a function that re-raises; and a WHEN ANY handler that
# re-raises - which must preserve the ORIGINAL exception's identity (a
# DIFFERENT exception than the one the WHEN EXCEPTION names). The
# per-level "At function/procedure" frame fc omits is stripped.
#
# Boundary (recorded): a TRIGGER body with a re-raise still refuses at
# CREATE - triggers compile through the server's own BLR emitter (not
# dsql), which does not emit the re-raise verb yet.
#
#   qa/serve-real-reraise.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4927}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-reraise-crab.fdb"; B="$D/fc-reraise-engine.fdb"
LOG="/tmp/fc-serve-reraise-$PORT.log"
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
CREATE EXCEPTION E_NEG 'value is negative'^
CREATE EXCEPTION E_OTHER 'other'^
CREATE PROCEDURE P1(A INT) RETURNS (R INT) AS BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; WHEN EXCEPTION E_NEG DO BEGIN R=-1; EXCEPTION; END END SUSPEND; END^
CREATE FUNCTION F1(A INT) RETURNS INT AS DECLARE R INT; BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; WHEN EXCEPTION E_NEG DO EXCEPTION; END RETURN R; END^
CREATE PROCEDURE P3(A INT) RETURNS (R INT) AS BEGIN BEGIN IF(A<0)THEN EXCEPTION E_OTHER; R=A; WHEN ANY DO EXCEPTION; END SUSPEND; END^
CREATE PROCEDURE PNOOP(A INT) RETURNS (R INT) AS BEGIN R=A; EXCEPTION; SUSPEND; END^
CREATE PROCEDURE PAFTER(A INT) RETURNS (R INT) AS BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; WHEN EXCEPTION E_NEG DO R=-1; END EXCEPTION; SUSPEND; END^
CREATE EXCEPTION E_INNER 'inner exc'^
CREATE PROCEDURE PN_AFTER(A INT) RETURNS (R INT) AS BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; WHEN EXCEPTION E_NEG DO BEGIN BEGIN EXCEPTION E_INNER; WHEN EXCEPTION E_INNER DO R=99; END EXCEPTION; END END SUSPEND; END^
CREATE PROCEDURE PN_BEFORE(A INT) RETURNS (R INT) AS BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; WHEN EXCEPTION E_NEG DO BEGIN EXCEPTION; R=99; END END SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | enorm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | enorm)
check "the re-raising routines build on both" "$c" "$e"

cat > "$D/r.sql" <<'SQL'
SET LIST ON;
SELECT R FROM P1(5);
SELECT R FROM P1(-3);
SELECT F1(9) R FROM RDB$DATABASE;
SELECT F1(-7) R FROM RDB$DATABASE;
SELECT R FROM P3(5);
SELECT R FROM P3(-3);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/r.sql" 2>&1 | enorm; }
check "re-raise from a proc / function / WHEN ANY, identity preserved" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a bare EXCEPTION; with NOTHING live to re-raise is a NO-OP on the
# engine, NOT an error (probed): at the top of a body (PNOOP), and AFTER
# a handler has already completed (PAFTER) - f.caught is handler-scoped,
# so execution simply falls through. (The engine accepts the CREATE too,
# so fc must not create-then-fail.)
cat > "$D/r.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PNOOP(5);
SELECT R FROM PAFTER(5);
SELECT R FROM PAFTER(-3);
SQL
check "a re-raise with nothing live is a no-op (top of body / after a handler)" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# NESTED handlers: a re-raise reached AFTER an inner handler completed is a
# no-op (the engine CLEARS the in-flight exception, it does NOT restore the
# outer one - PN_AFTER=99); a re-raise BEFORE any inner block re-raises the
# outer exception (PN_BEFORE). f.caught is set for the handler body and
# CLEARED afterwards, never restored to an outer level.
cat > "$D/r.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PN_AFTER(-3);
SELECT R FROM PN_BEFORE(-3);
SQL
check "nested re-raise: cleared after an inner handler (no-op), else the outer" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored re-raise BLR (blr_abort, 5)
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/r.sql" <<'SQL'
SET LIST ON;
SELECT R FROM P1(-3);
SELECT R FROM P3(-9);
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/r.sql" 2>&1 | enorm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/r.sql" 2>&1 | enorm)
check "the ENGINE runs fc's stored re-raise BLR" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q 'E_OTHER'; then echo "OK   re-raise preserved E_OTHER's identity via fc's stored BLR"; else
    echo "DIFF re-raise identity lost: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
