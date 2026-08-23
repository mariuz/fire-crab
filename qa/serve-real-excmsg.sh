#!/bin/bash
# EXCEPTION <name> '<literal>' - a raise that OVERRIDES the exception's
# catalog message with a literal. fc refused any message operand; probed
# from the engine's stored BLR, an override is blr_abort,6,<name> then a
# blr_literal blr_text2 (charset 0, u16 length) where a plain named raise
# is blr_abort,2,<name>. Both the dsql compiler (CREATE PROCEDURE/FUNCTION)
# and the server's trigger emitter now emit it, and the source interpreter
# uses the literal in the raised vector; the ENGINE runs the BLR fc stored.
#
# Covered: a procedure and a function raising with an override vs the
# catalog default, a doubled-quote ('') message, and a trigger override
# fired by the ENGINE from fc's file. The per-level stack frame fc omits
# is stripped.
#
# Boundaries (recorded):
#  - a non-literal message - an EXPRESSION ('v='||A) or a USING clause -
#    still refuses at CREATE (the body's expression surface is
#    arithmetic-only; fc cannot build the message text). The engine
#    accepts those, so fc refusing is a deliberate divergence.
#  - a very long message (~32000+ bytes) refuses at CREATE: fc's
#    string-literal parser caps below the engine's (pre-existing, applies
#    to any literal). fc therefore never stores a message near the u16
#    length field's ceiling, so that field cannot overflow.
#  - a NON-ASCII message renders mojibake in fc's OWN execution (a
#    pre-existing fc-wide exception-message encoding issue: a plain
#    catalog message does the same) - so this gate uses ASCII. fc stores
#    the correct bytes, and the ENGINE reading fc's file renders it right.
#
#   qa/serve-real-excmsg.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4939}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-excmsg-crab.fdb"; B="$D/fc-excmsg-engine.fdb"
LOG="/tmp/fc-serve-excmsg-$PORT.log"
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
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d; /-At procedure/d; /-At trigger/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE TABLE T (ID INT, V INT)^
CREATE EXCEPTION E_NEG 'default message'^
CREATE PROCEDURE PLIT(A INT) RETURNS (R INT) AS BEGIN IF(A<0)THEN EXCEPTION E_NEG 'custom literal here'; R=A; SUSPEND; END^
CREATE PROCEDURE PDEF(A INT) RETURNS (R INT) AS BEGIN IF(A<0)THEN EXCEPTION E_NEG; R=A; SUSPEND; END^
CREATE PROCEDURE PQUOTE(A INT) RETURNS (R INT) AS BEGIN IF(A<0)THEN EXCEPTION E_NEG 'it''s bad'; R=A; SUSPEND; END^
CREATE FUNCTION FLIT(A INT) RETURNS INT AS BEGIN IF(A<0)THEN EXCEPTION E_NEG 'fn message'; RETURN A; END^
CREATE PROCEDURE PNOSPACE(A INT) RETURNS (R INT) AS BEGIN IF(A<0)THEN EXCEPTION E_NEG'nospace'; R=A; SUSPEND; END^
CREATE TRIGGER TG FOR T BEFORE INSERT AS BEGIN IF (NEW.V < 0) THEN EXCEPTION E_NEG 'trigger override msg'; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | enorm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | enorm)
check "the message-override routines build on both" "$c" "$e"

# fc RUNS its own procedures/functions: override vs catalog default
cat > "$D/m.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PLIT(-1);
SELECT R FROM PDEF(-1);
SELECT R FROM PQUOTE(-1);
SELECT FLIT(-2) R FROM RDB$DATABASE;
SELECT R FROM PNOSPACE(-1);
SELECT R FROM PLIT(5);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/m.sql" 2>&1 | enorm; }
check "override / default / doubled-quote / no-space / function message, fc runs its own" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored BLR: the procedures AND the trigger fired on INSERT
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/m.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PLIT(-1);
SELECT FLIT(-9) R FROM RDB$DATABASE;
INSERT INTO T VALUES (1, 5);
INSERT INTO T VALUES (2, -3);
SELECT COUNT(*) C FROM T;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/m.sql" 2>&1 | enorm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/m.sql" 2>&1 | enorm)
check "the ENGINE runs fc's stored override BLR (procedures + trigger)" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q 'trigger override msg'; then echo "OK   trigger override fired via fc's stored BLR"; else
    echo "DIFF trigger override not seen: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
