#!/bin/bash
# PSQL loop control: `CONTINUE` (next iteration) and bare `LEAVE` (end
# the innermost loop), in WHILE and FOR SELECT loops, nested. fc had
# EXIT and could interpret a bare LEAVE it read from an engine-built
# procedure, but its own compiler (dsql) rejected LEAVE and CONTINUE;
# now it compiles both to blr_leave / blr_continue_loop over the loop's
# label, byte-for-byte with the engine, and the interpreter runs them.
# Both databases build the procedures; the SUSPENDed rows are compared,
# and the ENGINE runs the BLR fc stored.
#
# Boundaries (recorded): a LABELLED leave/continue (`LEAVE lbl`) is not
# taken - fc refuses where the engine builds it; a CONTINUE or LEAVE
# outside every loop refuses on both.
#
#   qa/serve-real-loopctl.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4895}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-loopctl-crab.fdb"; B="$D/fc-loopctl-engine.fdb"
LOG="/tmp/fc-serve-loopctl-$PORT.log"
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

cat > "$D/loopctl-setup.sql" <<'SQL'
CREATE TABLE T (ID INTEGER);
INSERT INTO T VALUES (1); INSERT INTO T VALUES (2); INSERT INTO T VALUES (3);
INSERT INTO T VALUES (4); INSERT INTO T VALUES (5);
COMMIT;
SET TERM ^;
CREATE PROCEDURE PWHILE RETURNS (N INTEGER) AS DECLARE I INTEGER; BEGIN I = 0; WHILE (I < 5) DO BEGIN I = I + 1; IF (I = 2) THEN CONTINUE; IF (I = 4) THEN LEAVE; N = I; SUSPEND; END END^
CREATE PROCEDURE PFOR RETURNS (N INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY ID INTO :N DO BEGIN IF (N = 2) THEN CONTINUE; IF (N = 4) THEN LEAVE; SUSPEND; END END^
CREATE PROCEDURE PNEST RETURNS (A INTEGER, B INTEGER) AS DECLARE I INTEGER; DECLARE J INTEGER; BEGIN I = 0; WHILE (I < 3) DO BEGIN I = I + 1; J = 0; WHILE (J < 3) DO BEGIN J = J + 1; IF (J = 2) THEN CONTINUE; IF (I = 3) THEN LEAVE; A = I; B = J; SUSPEND; END END END^
CREATE PROCEDURE PMIX RETURNS (N INTEGER) AS DECLARE K INTEGER; BEGIN FOR SELECT ID FROM T ORDER BY ID INTO :N DO BEGIN K = 0; WHILE (K < 2) DO BEGIN K = K + 1; IF (K = 1) THEN CONTINUE; END IF (N = 3) THEN CONTINUE; IF (N = 5) THEN LEAVE; SUSPEND; END END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/loopctl-setup.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/loopctl-setup.sql" 2>&1 | norm)
check "the loop-control procedures build on both" "$c" "$e"

cat > "$D/loopctl-run.sql" <<'SQL'
SET LIST ON;
SELECT N FROM PWHILE;
SELECT N FROM PFOR;
SELECT A, B FROM PNEST;
SELECT N FROM PMIX;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/loopctl-run.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/loopctl-run.sql" 2>&1 | norm)
check "CONTINUE / LEAVE over WHILE, FOR SELECT and nested loops" "$c" "$e"

# the ENGINE runs the BLR fc stored (proves the compiled loop control is valid)
e=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/loopctl-run.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/loopctl-run.sql" 2>&1 | norm)
check "the ENGINE runs the loop-control BLR fc stored" "$c" "$e"

# Boundary: a labelled leave and out-of-loop control refuse on fc
for q in "CREATE PROCEDURE PLBL RETURNS (N INTEGER) AS DECLARE I INTEGER; BEGIN I=0; LP: WHILE (I<3) DO BEGIN I=I+1; N=I; SUSPEND; IF (I=2) THEN LEAVE LP; END END" \
         "CREATE PROCEDURE POUT RETURNS (N INTEGER) AS BEGIN CONTINUE; END" \
         "CREATE PROCEDURE PLO RETURNS (N INTEGER) AS BEGIN LEAVE; END"; do
    printf 'SET TERM ^;\n%s^\nSET TERM ;^\nCOMMIT;\n' "$q" > "$D/loopctl-b.sql"
    c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/loopctl-b.sql" 2>&1 | grep -ci error)
    ran=$((ran + 1))
    if [ "$c" != "0" ]; then echo "OK   boundary refuses on fc: ${q:0:38}..."
    else echo "DIFF boundary was accepted: $q"; fail=1; fi
done

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
