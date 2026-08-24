#!/bin/bash
# CONTEXT / keyword parameter DEFAULTs - `A VARCHAR DEFAULT CURRENT_USER`,
# `DEFAULT CURRENT_ROLE`, `DEFAULT CURRENT_CONNECTION`, `DEFAULT
# CURRENT_DATE/TIME/TIMESTAMP` - resolved per call, not a fixed literal.
# dsql's default parser accepts the keyword, proc_default_of stores the
# engine's own keyword BLR (byte-identical) + the verbatim source, and the
# fill evaluates it per call from the session (SessionCtx / clock): a
# ProcParam carries the UNEVALUATED DefaultVal (default_ctx) and
# with_proc_defaults resolves it where a ctx is in reach - the source path
# (EXECUTE PROCEDURE, a selectable procedure at execute) and the select-list
# function materialisation. The ctx-less BLR fast paths leave a context
# default short so the call falls to the source path.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): all seven
# keyword routines build; the catalog RDB$DEFAULT_SOURCE and RDB$DEFAULT_VALUE
# BLR match; fc SERVES the login/role forms (SYSDBA / NONE - the same on both
# sides); a provided argument beats the default; a missing REQUIRED argument
# is the byte-exact vector; the DATE default is filled when the ENGINE runs
# fc's file; gfix.
#
# Boundaries (recorded): CURRENT_TRANSACTION is refused at CREATE (its id is
# not in the fill's reach); a DATE/TIME/TIMESTAMP-typed routine BODY is not
# one fc's arithmetic source interpreter runs (a pre-existing gap, orthogonal
# to defaults), so fc stores those context defaults and the ENGINE reads them
# but fc does not itself serve the fill; CURRENT_CONNECTION fills fc's own
# attachment id (self-referential, not cross-comparable); a PSQL BODY call
# omitting a context-defaulted argument refuses (exe has no context opcode).
#
#   qa/serve-real-ctxdefault.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4946}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ctxdef-crab.fdb"; B="$D/fc-ctxdef-engine.fdb"
LOG="/tmp/fc-serve-ctxdef-$PORT.log"
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE FUNCTION FU(A INTEGER, X VARCHAR(40) DEFAULT CURRENT_USER) RETURNS VARCHAR(40) AS BEGIN RETURN X; END^
CREATE FUNCTION FU2(A INTEGER, X VARCHAR(40) DEFAULT USER) RETURNS VARCHAR(40) AS BEGIN RETURN X; END^
CREATE FUNCTION FR(A INTEGER, X VARCHAR(40) DEFAULT CURRENT_ROLE) RETURNS VARCHAR(40) AS BEGIN RETURN X; END^
CREATE FUNCTION FCC(A INTEGER, X INTEGER DEFAULT CURRENT_CONNECTION) RETURNS INTEGER AS BEGIN RETURN X; END^
CREATE PROCEDURE PLOG(MSG VARCHAR(10), WHO VARCHAR(40) DEFAULT CURRENT_USER, RL VARCHAR(40) DEFAULT CURRENT_ROLE) RETURNS (W VARCHAR(40), R VARCHAR(40)) AS BEGIN W=WHO; R=RL; SUSPEND; END^
CREATE PROCEDURE PDT(A INTEGER, D DATE DEFAULT CURRENT_DATE) RETURNS (R DATE) AS BEGIN R=D; SUSPEND; END^
CREATE PROCEDURE PTM(A INTEGER, T TIME DEFAULT CURRENT_TIME) RETURNS (R TIME) AS BEGIN R=T; SUSPEND; END^
CREATE PROCEDURE PTS(A INTEGER, T TIMESTAMP DEFAULT CURRENT_TIMESTAMP) RETURNS (R TIMESTAMP) AS BEGIN R=T; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "all seven context-default routines build on both" "$c" "$e"

cat > "$D/cat.sql" <<'SQL'
SET LIST ON;
SELECT RDB$FUNCTION_NAME||'.'||RDB$ARGUMENT_NAME N, CAST(RDB$DEFAULT_SOURCE AS VARCHAR(22)) S
FROM RDB$FUNCTION_ARGUMENTS WHERE RDB$DEFAULT_SOURCE IS NOT NULL ORDER BY 1;
SELECT RDB$PROCEDURE_NAME||'.'||RDB$PARAMETER_NAME N, CAST(RDB$DEFAULT_SOURCE AS VARCHAR(22)) S
FROM RDB$PROCEDURE_PARAMETERS WHERE RDB$DEFAULT_SOURCE IS NOT NULL ORDER BY 1;
SQL
catof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cat.sql" 2>&1 | norm; }
check "the catalog default source matches (all seven)" \
    "$(catof "127.0.0.1/$PORT:$A")" "$(catof "127.0.0.1/$REAL:$B")"

cat > "$D/srv.sql" <<'SQL'
SET LIST ON;
SELECT FU(1) R FROM RDB$DATABASE;
SELECT FU2(1) R FROM RDB$DATABASE;
SELECT FR(1) R FROM RDB$DATABASE;
SELECT FU(1, 'BOB') R FROM RDB$DATABASE;
SELECT W, R FROM PLOG('hi');
SELECT W FROM PLOG('hi', 'AL');
SQL
srvof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/srv.sql" 2>&1 | norm; }
check "fc serves the login/role context defaults, and a provided arg wins" \
    "$(srvof "127.0.0.1/$PORT:$A")" "$(srvof "127.0.0.1/$REAL:$B")"

# a missing REQUIRED argument is the byte-exact vector; too many refuses
cat > "$D/m.sql" <<'SQL'
SET LIST ON;
SELECT FU() R FROM RDB$DATABASE;
SELECT FU(1,'a','b') R FROM RDB$DATABASE;
SQL
mof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/m.sql" 2>&1 | norm; }
check "missing-required / too-many context-default calls: byte-exact" \
    "$(mof "127.0.0.1/$PORT:$A")" "$(mof "127.0.0.1/$REAL:$B")"

# CURRENT_CONNECTION fills fc's own attachment id (self-referential): assert
# fc returns an integer, and a provided value still wins
ran=$((ran + 1))
cc=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' 2>&1 | norm
SET LIST ON;
SELECT FCC(1, 77) R FROM RDB$DATABASE;
SQL
)
if echo "$cc" | grep -q "R 77"; then echo "OK   CURRENT_CONNECTION param: a provided value wins (self-referential default)"; else
    echo "DIFF CURRENT_CONNECTION param: [$cc]"; fail=1; fi

# the ENGINE runs fc's stored context defaults (login/role, and the DATE
# whose value is stable within the day)
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/ef.sql" <<'SQL'
SET LIST ON;
SELECT W, R FROM PLOG('x');
SELECT R FROM PDT(1);
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/ef.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/ef.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored context defaults (login/role + CURRENT_DATE)" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "W SYSDBA"; then echo "OK   PLOG fills CURRENT_USER=SYSDBA via fc's file"; else
    echo "DIFF login default not filled: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

# Boundary: CURRENT_TRANSACTION refuses at CREATE on fc (engine accepts)
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >>"$LOG" 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
ran=$((ran + 1))
tx=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' 2>&1
SET TERM ^;
CREATE FUNCTION FTX(A INTEGER, X INTEGER DEFAULT CURRENT_TRANSACTION) RETURNS INTEGER AS BEGIN RETURN X; END^
SET TERM ;^
COMMIT;
SELECT RDB$FUNCTION_NAME FROM RDB$FUNCTIONS WHERE RDB$FUNCTION_NAME='FTX' AND RDB$PACKAGE_NAME IS NULL;
SQL
)
if echo "$tx" | grep -q "FTX"; then echo "DIFF fc stored CURRENT_TRANSACTION default it cannot fill: $tx"; fail=1;
else echo "OK   CURRENT_TRANSACTION default refused at CREATE (boundary)"; fi
kill $srv 2>/dev/null; wait $srv 2>/dev/null

echo "ran $ran checks"
exit $fail
