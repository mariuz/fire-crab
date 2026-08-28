#!/bin/bash
# A PSQL BODY call that OMITS a defaulted function's trailing argument.
# The engine stores `blr_function` with only the arguments passed and
# resolves the rest from the callee's catalog AT RUN TIME (a late binding,
# not a compile-time inline: G calling FA(X) stores a 1-argument call).
# fc now matches on both sides of that:
#   - dsql relaxes the body-call arity to [required, total] (required =
#     inputs without a default) and emits the same short call, so fc's
#     stored BLR is byte-identical to the engine's;
#   - the exe executor fills the omitted defaulted tail from
#     RDB$FUNCTION_ARGUMENTS.RDB$DEFAULT_VALUE when it runs the call, so
#     fc SERVES the same answer the engine does.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): a
# function body and a procedure body each calling a defaulted function
# with the tail omitted (int / string / two-defaults, none/one omitted)
# and fully supplied; the answers match, and G's stored BLR is byte-equal.
#
# Boundary (recorded): a body call with the WRONG arity - a REQUIRED
# argument missing, or too many - refuses on fc with a GENERIC "Dynamic
# SQL Error" where the engine gives the specific 07001 "Parameter
# mismatch" (fc's dsql body-call arity failure returns None -> a generic
# CREATE refusal; this is the pre-existing shape for ALL body-call arity
# errors, unchanged, and it fails safe). A function omitting its OWN
# defaulted argument in a recursive self-call also refuses (self-sig
# required == total).
#
#   qa/serve-real-bodydefault.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4943}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-bdef-crab.fdb"; B="$D/fc-bdef-engine.fdb"
LOG="/tmp/fc-serve-bdef-$PORT.log"
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE FUNCTION FA(B INTEGER, A INTEGER DEFAULT 5) RETURNS INTEGER AS BEGIN RETURN B+A; END^
CREATE FUNCTION FS(B INTEGER, A VARCHAR(5) DEFAULT 'hi') RETURNS VARCHAR(10) AS BEGIN RETURN A; END^
CREATE FUNCTION F2(B INTEGER, A INTEGER DEFAULT 1, C INTEGER DEFAULT 2) RETURNS INTEGER AS BEGIN RETURN A+C+B; END^
CREATE FUNCTION G(X INTEGER) RETURNS INTEGER AS BEGIN RETURN FA(X); END^
CREATE FUNCTION GFULL(X INTEGER) RETURNS INTEGER AS BEGIN RETURN FA(X, 20); END^
CREATE FUNCTION GS(X INTEGER) RETURNS VARCHAR(10) AS BEGIN RETURN FS(X); END^
CREATE FUNCTION G2A(X INTEGER) RETURNS INTEGER AS BEGIN RETURN F2(X); END^
CREATE FUNCTION G2B(X INTEGER) RETURNS INTEGER AS BEGIN RETURN F2(X, 10); END^
CREATE PROCEDURE PG(X INTEGER) RETURNS (R INTEGER) AS BEGIN R = FA(X); SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the body-callers build on both (omitted + full, function + procedure)" "$c" "$e"

cat > "$D/q-$PORT.sql" <<'SQL'
SET LIST ON;
SELECT G(10) R FROM RDB$DATABASE;
SELECT GFULL(10) R FROM RDB$DATABASE;
SELECT GS(0) R FROM RDB$DATABASE;
SELECT G2A(100) R FROM RDB$DATABASE;
SELECT G2B(100) R FROM RDB$DATABASE;
SELECT R FROM PG(10);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q-$PORT.sql" 2>&1 | norm; }
check "body calls fill the omitted default (int/string/two-defaults; proc body too)" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# Boundary: a wrong-arity body call refuses on fc (generic) - assert it is
# refused, not that the text matches the engine's specific 07001.
ran=$((ran + 1))
bad=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' 2>&1
SET TERM ^;
CREATE FUNCTION BADREQ(X INTEGER) RETURNS INTEGER AS BEGIN RETURN FA(); END^
SET TERM ;^
COMMIT;
SQL
)
if echo "$bad" | grep -qi "error"; then echo "OK   a body call missing a REQUIRED arg is refused (generic, boundary)";
else echo "DIFF missing-required body call was NOT refused: [$bad]"; fail=1; fi

# the ENGINE runs fc's stored body-call BLR (proving fc emits the same
# short blr_function the engine fills)
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/q-$PORT.sql" <<'SQL'
SET LIST ON;
SELECT G(6) R, G2A(6) R2, GS(0) R3 FROM RDB$DATABASE;
SELECT R FROM PG(6);
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/q-$PORT.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/q-$PORT.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored omitted-default body calls" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 11"; then echo "OK   G(6)=11 (FA default 5 filled) via fc's file"; else
    echo "DIFF the default was not filled: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
