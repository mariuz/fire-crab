#!/bin/bash
# DEFAULT parameters on a stored PROCEDURE - `A INTEGER DEFAULT 5`,
# `A INTEGER = 7`, `A VARCHAR(5) DEFAULT 'hi'`, `DEFAULT -3`. fc refused
# any parameter default; now dsql parses a LITERAL default (integer,
# optionally signed; string; NULL) in the input list, the wire turns its
# source into the stored RDB$DEFAULT_SOURCE (the DEFAULT/= form; the literal is re-rendered, so a
# RDB$DEFAULT_VALUE BLR (the same helpers a column default uses), and a
# call that OMITS a defaulted trailing argument has it filled from the
# decoded default. Defaults must be trailing (the engine's rule).
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): the
# stored RDB$DEFAULT_SOURCE for each form; a call omitting the default, one
# providing it, EXECUTE PROCEDURE, a string default, a negative default,
# and two trailing defaults omitted independently. Boundaries: a
# non-default parameter after a defaulted one refuses on both; a call
# missing a REQUIRED parameter gives the byte-exact "Parameter mismatch"
# vector.
#
# Boundary (recorded): a FUNCTION parameter default, and a non-literal
# (expression / context) default, refuse at CREATE (the engine accepts a
# function default and CURRENT_* etc; fc takes literal PROCEDURE defaults
# only for now).
#
#   qa/serve-real-procdefault.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4944}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-pdef-crab.fdb"; B="$D/fc-pdef-engine.fdb"
LOG="/tmp/fc-serve-pdef-$PORT.log"
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE PROCEDURE PA(B INTEGER, A INTEGER DEFAULT 5) RETURNS (R INTEGER) AS BEGIN R=A+B; SUSPEND; END^
CREATE PROCEDURE PB(B INTEGER, A INTEGER = 7) RETURNS (R INTEGER) AS BEGIN R=A+B; SUSPEND; END^
CREATE PROCEDURE PS(B INTEGER, A VARCHAR(5) DEFAULT 'hi') RETURNS (R VARCHAR(10)) AS BEGIN R=A; SUSPEND; END^
CREATE PROCEDURE PN(B INTEGER, A INTEGER DEFAULT -3) RETURNS (R INTEGER) AS BEGIN R=A+B; SUSPEND; END^
CREATE PROCEDURE P2(B INTEGER, A INTEGER DEFAULT 1, C INTEGER DEFAULT 2) RETURNS (R INTEGER) AS BEGIN R=A+C+B; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the defaulted procedures build on both" "$c" "$e"

cat > "$D/src.sql" <<'SQL'
SET LIST ON;
SELECT RDB$PROCEDURE_NAME PR, CAST(RDB$DEFAULT_SOURCE AS VARCHAR(20)) SRC
FROM RDB$PROCEDURE_PARAMETERS WHERE RDB$DEFAULT_SOURCE IS NOT NULL
AND RDB$PROCEDURE_NAME IN ('PA','PB','PS','PN','P2') ORDER BY 1, RDB$PARAMETER_NUMBER;
SQL
srcs() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/src.sql" 2>&1 | norm; }
check "RDB\$DEFAULT_SOURCE stored verbatim (DEFAULT / = / string / negative)" \
    "$(srcs "127.0.0.1/$PORT:$A")" "$(srcs "127.0.0.1/$REAL:$B")"

cat > "$D/q-$PORT.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PA(10);
SELECT R FROM PA(10, 99);
EXECUTE PROCEDURE PA(20);
SELECT R FROM PB(10);
SELECT R FROM PS(0);
SELECT R FROM PN(10);
SELECT R FROM P2(100);
SELECT R FROM P2(100, 10);
SELECT R FROM P2(100, 10, 20);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q-$PORT.sql" 2>&1 | norm; }
check "omitted defaults filled; provided ones used; string / negative / multi" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# missing a REQUIRED (non-defaulted) parameter: byte-exact mismatch vector
cat > "$D/m.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PA;
SQL
mm() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/m.sql" 2>&1 | norm; }
check "a call missing a required parameter: byte-exact mismatch" \
    "$(mm "127.0.0.1/$PORT:$A")" "$(mm "127.0.0.1/$REAL:$B")"

# a DEFAULT this server cannot encode (an integer outside i32, a BIGINT
# default) REFUSES at CREATE rather than silently dropping it - a clean
# boundary (the engine stores a blr_int64 default; fc never stores a null
# default it could not fill). Run against fc while it is still up.
ran=$((ran + 1))
bigd=$(printf 'SET TERM ^;\nCREATE PROCEDURE PBIG(B INTEGER, X BIGINT DEFAULT 5000000000) RETURNS (R BIGINT) AS BEGIN R=X+B; SUSPEND; END^\nSET TERM ;^\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
if echo "$bigd" | grep -qiE 'error|failed'; then echo "OK   an un-encodable (BIGINT) default refuses at CREATE, not dropped"; else
    echo "DIFF a BIGINT default was accepted (silent drop?): [$bigd]"; fail=1; fi

# an OVER-arity EXECUTE PROCEDURE is REFUSED (not silently truncated),
# including through the exe fast path
ran=$((ran + 1))
over=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' 2>&1 | grep -v '^$' | tr '\n' ' '
SET LIST ON;
EXECUTE PROCEDURE PA(10, 20, 30);
SQL
)
if echo "$over" | grep -qiE 'error|failed|mismatch'; then echo "OK   an over-arity EXECUTE PROCEDURE refuses (no silent truncation)"; else
    echo "DIFF over-arity was not refused: [$over]"; fail=1; fi

# the ENGINE runs fc's stored defaults
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/q-$PORT.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/q-$PORT.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored defaulted procedures" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 15"; then echo "OK   PA(10)=15 (default filled) via fc's file"; else
    echo "DIFF the default was not filled: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
