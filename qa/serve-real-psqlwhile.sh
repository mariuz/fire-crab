#!/bin/bash
# WHILE / CONTINUE in the exe BLR executor - blr_loop and blr_continue_loop.
# exe could not convert a loop, so a WHILE body combining loop control with
# an exe-only feature (a NUMERIC accumulation, a function call) fell to the
# source path and refused. exe now runs the loop: blr_label folds into the
# loop it wraps so LEAVE ends it and CONTINUE moves to the next iteration;
# a FOR SELECT loop's CONTINUE goes to the next row, not out of the loop.
#
# Covered: a NUMERIC accumulator over a WHILE, a WHILE with CONTINUE, a
# nested WHILE with a labelled LEAVE to the OUTER loop, and a WHILE whose
# body CALLS a function (loop + blr_function2). Both servers run the same
# queries and the rows are compared; the ENGINE runs the BLR fc stored.
# (The bare CONTINUE/LEAVE semantics themselves are pinned by
# serve-real-loopctl, which now runs its procedures through exe.)
#
# Boundary (recorded): an INFINITE loop hangs (as it does on the engine);
# a body that recurses past the guard refuses (serve-real-fncall).
#
#   qa/serve-real-psqlwhile.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4923}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-psqlwhile-crab.fdb"; B="$D/fc-psqlwhile-engine.fdb"
LOG="/tmp/fc-serve-psqlwhile-$PORT.log"
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
CREATE FUNCTION FNSUM(N INTEGER) RETURNS NUMERIC(9,2) AS DECLARE I INTEGER; DECLARE S NUMERIC(9,2); BEGIN S = 0; I = 1; WHILE (I <= N) DO BEGIN S = S + I * 0.5; I = I + 1; END RETURN S; END^
CREATE FUNCTION FNCONT(N INTEGER) RETURNS NUMERIC(9,2) AS DECLARE I INTEGER; DECLARE S NUMERIC(9,2); BEGIN S = 0; I = 0; WHILE (I < N) DO BEGIN I = I + 1; IF (I = 3) THEN BEGIN CONTINUE; END S = S + I * 1.5; END RETURN S; END^
CREATE FUNCTION FNEST(N INTEGER) RETURNS INTEGER AS DECLARE I INTEGER; DECLARE J INTEGER; DECLARE S INTEGER; BEGIN S = 0; I = 0; OUT: WHILE (I < N) DO BEGIN I = I + 1; J = 0; WHILE (J < N) DO BEGIN J = J + 1; IF (J = 2 AND I = 2) THEN LEAVE OUT; S = S + 1; END END RETURN S; END^
CREATE PACKAGE PK AS BEGIN FUNCTION DBL(A INTEGER) RETURNS INTEGER; FUNCTION SUMD(N INTEGER) RETURNS INTEGER; END^
CREATE PACKAGE BODY PK AS BEGIN
  FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 2; END
  FUNCTION SUMD(N INTEGER) RETURNS INTEGER AS DECLARE I INTEGER; DECLARE S INTEGER; BEGIN S = 0; I = 0; WHILE (I < N) DO BEGIN I = I + 1; S = S + DBL(I); END RETURN S; END
END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the WHILE-bodied routines build on both" "$c" "$e"

cat > "$D/w.sql" <<'SQL'
SET LIST ON;
SELECT FNSUM(4) R FROM RDB$DATABASE;
SELECT FNSUM(0) R FROM RDB$DATABASE;
SELECT FNCONT(5) R FROM RDB$DATABASE;
SELECT FNEST(3) R FROM RDB$DATABASE;
SELECT FNEST(1) R FROM RDB$DATABASE;
SELECT PK.SUMD(4) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/w.sql" 2>&1 | norm; }
check "WHILE+NUMERIC / WHILE+CONTINUE / nested+labelled-LEAVE / WHILE+function-call" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored WHILE BLR
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/w.sql" <<'SQL'
SET LIST ON;
SELECT FNSUM(6) R, FNCONT(6) R2, PK.SUMD(5) R3 FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/w.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/w.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored WHILE BLR" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R3 30"; then echo "OK   SUMD(5)=30 (WHILE+call) via fc's stored BLR"; else
    echo "DIFF SUMD did not compute: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
