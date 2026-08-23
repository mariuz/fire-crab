#!/bin/bash
# PSQL exception HANDLERS - a BEGIN..END block with WHEN ... DO clauses -
# over the wire. The source interpreter already ran handlers (its block AST
# carries a Vec of conditions per handler and splits the WHEN list on the
# comma); the dsql COMPILER lagged in one place: it read a single condition
# per WHEN and emitted a hard-coded code-count of 1, so a MULTI-CONDITION
# handler (WHEN EXCEPTION A, EXCEPTION B DO) refused at CREATE. dsql now
# parses the comma list and emits blr_error_handler with the real count,
# and the ENGINE runs the BLR fc stored.
#
# Covered (all compared byte-for-byte, fc vs the live engine, and the
# ENGINE re-runs fc's stored BLR): a single WHEN EXCEPTION <name> catching
# the named one and letting another propagate; WHEN GDSCODE (a system error
# by name); WHEN SQLCODE; nested handlers (inner + outer); a handler in a
# FUNCTION; a MULTI-CONDITION handler mixing EXCEPTION and GDSCODE; and
# WHEN ANY inside a comma list (WHEN ANY, EXCEPTION E) which the engine
# runs as a catch-all - fc compiles AND runs it (a raise not in the
# explicit list is still caught), no create-then-run inconsistency.
#
# The per-level "At function/procedure" stack frame fc omits is stripped
# (a recorded fc-wide boundary), so enorm drops it on both sides.
#
# Boundaries (recorded, refused at CREATE): a re-raise `EXCEPTION;` inside a
# handler, and a user-function CALL in a body statement (R = F(A)) - the
# body's expression surface is arithmetic-only (a separate, pre-existing
# dsql gap, not exception-specific).
#
#   qa/serve-real-whenexc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4926}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-whenexc-crab.fdb"; B="$D/fc-whenexc-engine.fdb"
LOG="/tmp/fc-serve-whenexc-$PORT.log"
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
CREATE EXCEPTION E_BIG 'too big'^
CREATE PROCEDURE T1(A INT) RETURNS (R INT) AS
BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; IF(A>100)THEN EXCEPTION E_BIG; R=A; WHEN EXCEPTION E_NEG DO R=-1; END SUSPEND; END^
CREATE PROCEDURE TGDS(A INT, B INT) RETURNS (R INT) AS
BEGIN BEGIN R=A/B; WHEN GDSCODE arith_except DO R=-99; END SUSPEND; END^
CREATE PROCEDURE TSQL(A INT, B INT) RETURNS (R INT) AS
BEGIN BEGIN R=A/B; WHEN SQLCODE -802 DO R=-77; END SUSPEND; END^
CREATE PROCEDURE TNEST(A INT) RETURNS (R INT) AS
BEGIN BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; IF(A>100)THEN EXCEPTION E_BIG; R=A; WHEN EXCEPTION E_BIG DO R=-2; END WHEN EXCEPTION E_NEG DO R=-1; END SUSPEND; END^
CREATE PROCEDURE TMULTI(A INT) RETURNS (R INT) AS
BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; IF(A>100)THEN EXCEPTION E_BIG; R=A; WHEN EXCEPTION E_NEG, EXCEPTION E_BIG DO R=-5; END SUSPEND; END^
CREATE PROCEDURE TMIX(A INT, B INT) RETURNS (R INT) AS
BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A/B; WHEN EXCEPTION E_NEG, GDSCODE arith_except DO R=-1; END SUSPEND; END^
CREATE FUNCTION FCAT(A INT) RETURNS INT AS
DECLARE R INT;
BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; WHEN EXCEPTION E_NEG DO R=-1; END RETURN R; END^
CREATE PROCEDURE TANY(A INT) RETURNS (R INT) AS
BEGIN BEGIN IF(A<0)THEN EXCEPTION E_NEG; IF(A>100)THEN EXCEPTION E_BIG; R=A; WHEN ANY, EXCEPTION E_NEG DO R=-7; END SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | enorm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | enorm)
check "the handler-bodied routines (incl multi-condition) build on both" "$c" "$e"

cat > "$D/h.sql" <<'SQL'
SET LIST ON;
SELECT R FROM T1(5); SELECT R FROM T1(-3); SELECT R FROM T1(200);
SELECT R FROM TGDS(10,0); SELECT R FROM TGDS(10,2);
SELECT R FROM TSQL(10,0);
SELECT R FROM TNEST(-3); SELECT R FROM TNEST(200); SELECT R FROM TNEST(50);
SELECT R FROM TMULTI(-3); SELECT R FROM TMULTI(200); SELECT R FROM TMULTI(50);
SELECT R FROM TMIX(-3,5); SELECT R FROM TMIX(10,0); SELECT R FROM TMIX(10,2);
SELECT FCAT(-9) R FROM RDB$DATABASE; SELECT FCAT(7) R FROM RDB$DATABASE;
SELECT R FROM TANY(5); SELECT R FROM TANY(-3); SELECT R FROM TANY(200);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/h.sql" 2>&1 | enorm; }
check "single/GDSCODE/SQLCODE/nested/multi-condition/mixed/function/ANY-in-list handlers" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored handler BLR (the multi-condition one in
# particular exercises the blr_error_handler count fc now emits)
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/h.sql" <<'SQL'
SET LIST ON;
SELECT R FROM TMULTI(-3) M1; SELECT R FROM TMULTI(200) M2;
SELECT R FROM TMIX(10,0) X; SELECT R FROM TNEST(-3) N;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/h.sql" 2>&1 | enorm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/h.sql" 2>&1 | enorm)
check "the ENGINE runs fc's stored handler BLR (multi-condition included)" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q 'R -5'; then echo "OK   multi-condition handler ran via fc's stored BLR"; else
    echo "DIFF multi-condition did not run: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
