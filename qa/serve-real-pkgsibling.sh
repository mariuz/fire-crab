#!/bin/bash
# A PACKAGE BODY member that CALLS A SIBLING member unqualified - `FUNCTION
# QUAD ... AS BEGIN RETURN DBL(DBL(A)); END` beside `FUNCTION DBL`. Inside
# a package body a bare `DBL(...)` names the sibling member, which the
# engine (and now fc) compiles to blr_function2 with THIS package - the
# same encoding as the qualified `PK.DBL(...)`.
#
# Before the fix fc's per-member compile refused the sibling call, and the
# whole CREATE PACKAGE BODY fell through storing a NULL body source - which
# made EVERY function in the package unknown (-804) in later queries. Now
# the body compiles, its BLR is byte-identical to the engine's, and the
# non-cross-calling members answer through fc.
#
# The gate builds the same package on both servers, then proves the ENGINE
# runs fc's STORED FILE identically to its own for every member (the
# byte-for-byte BLR proof, the sibling-caller included), and that fc itself
# answers the non-cross-calling member over the wire.
#
# Boundary (recorded): a member that CALLS A SIBLING, queried through fc's
# OWN wire server, refuses - fc interprets bodies from source and does not
# yet run a user-function call from an interpreted body (a broader gap that
# holds for a plain function calling another function too). The stored BLR
# is correct, so the engine runs it; fc's own interpreter does not.
#
#   qa/serve-real-pkgsibling.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4896}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-pkgsib-crab.fdb"; B="$D/fc-pkgsib-engine.fdb"
LOG="/tmp/fc-serve-pkgsib-$PORT.log"
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
CREATE TABLE T (ID INTEGER);
INSERT INTO T VALUES (1); INSERT INTO T VALUES (2); INSERT INTO T VALUES (3);
COMMIT;
SET TERM ^;
CREATE PACKAGE PK AS BEGIN
  FUNCTION DBL(A INTEGER) RETURNS INTEGER;
  FUNCTION QUAD(A INTEGER) RETURNS INTEGER;
  FUNCTION TRP(A INTEGER) RETURNS INTEGER;
END^
CREATE PACKAGE BODY PK AS BEGIN
  FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 2; END
  FUNCTION QUAD(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(DBL(A)); END
  FUNCTION TRP(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3; END
END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the cross-calling package builds identically on both" "$c" "$e"

# fc answers the NON-cross-calling members over its own wire
cat > "$D/ps.sql" <<'SQL'
SET LIST ON;
SELECT ID, PK.DBL(ID) D, PK.TRP(ID) TR FROM T ORDER BY ID;
SELECT PK.DBL(5) D FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/ps.sql" 2>&1 | norm; }
check "fc answers the non-cross-calling members over the wire (were -804 before)" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the describe of a packaged function the wire announces
cat > "$D/ps.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT PK.DBL(ID) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/ps.sql" 2>&1 | grep -iE "sqltype|name:" | norm; }
check "packaged-function describe over the wire" "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# INVALID sibling forms the engine rejects at compile - fc must reject too,
# not store a body the engine would never create. A bare sibling call with
# the WRONG arg count, and a bare call to a sibling PROCEDURE in value
# position (a procedure is not a scalar function). Both build a fresh header
# first, then attempt the bad body.
HDR='SET TERM ^; CREATE PACKAGE PZ AS BEGIN FUNCTION DBL(A INTEGER) RETURNS INTEGER; FUNCTION Q(A INTEGER) RETURNS INTEGER; PROCEDURE SIB(A INTEGER) RETURNS (R INTEGER); END^ SET TERM ;^ COMMIT;'
for bad in \
  'FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A*2; END FUNCTION Q(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(A,A); END PROCEDURE SIB(A INTEGER) RETURNS (R INTEGER) AS BEGIN R=A; SUSPEND; END' \
  'FUNCTION DBL(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A*2; END FUNCTION Q(A INTEGER) RETURNS INTEGER AS BEGIN RETURN SIB(A); END PROCEDURE SIB(A INTEGER) RETURNS (R INTEGER) AS BEGIN R=A; SUSPEND; END'; do
    ecnt=0; ccnt=0
    for pair in "$REAL:$B:e" "$PORT:$A:c"; do
        pt="${pair%%:*}"; rest="${pair#*:}"; fdb="${rest%:*}"; which="${rest##*:}"
        "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$pt:$fdb" <<< "$HDR" >/dev/null 2>&1
        printf 'SET TERM ^;\nCREATE PACKAGE BODY PZ AS BEGIN %s END^\nSET TERM ;^\n' "$bad" > "$D/ps.sql"
        n=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$pt:$fdb" -i "$D/ps.sql" 2>&1 | grep -ciE 'error|fail')
        "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$pt:$fdb" <<< "DROP PACKAGE PZ;" >/dev/null 2>&1
        [ "$which" = "e" ] && ecnt=$n || ccnt=$n
    done
    ran=$((ran + 1))
    if [ "$ecnt" != "0" ] && [ "$ccnt" != "0" ]; then echo "OK   invalid sibling form refused on both: ${bad:60:30}"
    else echo "DIFF invalid sibling form (eng-errs=$ecnt fc-errs=$ccnt): ${bad:60:40}"; fail=1; fi
done

# the byte-for-byte BLR proof: the ENGINE runs fc's STORED FILE for EVERY
# member (the sibling-caller QUAD included) exactly as it runs its own.
# Stop fc first so the engine opens the file cleanly.
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/ps.sql" <<'SQL'
SET LIST ON;
SELECT ID, PK.DBL(ID) D, PK.QUAD(ID) Q, PK.TRP(ID) TR FROM T ORDER BY ID;
SELECT PK.QUAD(10) Q FROM RDB$DATABASE;
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/ps.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/ps.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored package - the sibling-caller QUAD included" "$cfile" "$efile"

# QUAD must actually compute (guard against both answering an error alike)
ran=$((ran + 1))
if echo "$cfile" | grep -q "Q 8"; then echo "OK   QUAD(2)=8 via fc's stored BLR"; else
    echo "DIFF QUAD did not compute: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
